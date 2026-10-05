#!/bin/bash
# The lab sshd: a user-level /usr/sbin/sshd that plays "the Mac" for lab guests, confined to
# the run sandbox. Never the system sshd, never port 22, never 0.0.0.0, never ~/.ssh.
#
#   sshd.sh keygen <root>      host key <root>/sshd/ssh_host_ed25519_key; prints the .pub path
#                              (before the agent starts: MACHMAN_LAB_SSHD_HOSTKEY pins it)
#   sshd.sh hostkey <root>     prints the .pub path
#   sshd.sh start --run <root> --bind loopback|vmnet [--port N] [--password] [--home <dir>]
#                 [--wait S]   prints host:port (also into <root>/sshd/address)
#   sshd.sh stop <root> | sweep <root>
#   sshd.sh authorize <root> <public key file>
#   sshd.sh doctor             firewall state and sshd version
#   sshd.sh --self-check
#
# Keys, config, log and authorized_keys live in <root>/sshd, the pid in <root>/pids/sshd.pid.
# Logins: the Mac user only, public key only (--password offers password auth, which can never
# succeed: UsePAM no — for the password-prompt rows). AuthorizedKeysFile is the fake home's
# .ssh/authorized_keys (where the product writes reverse grants) and <root>/sshd/authorized_keys.
# Sessions (session.sh) run with HOME = the fake home, under sandbox-exec: writes only inside
# the run root, /dev and the user's temp dir. --bind vmnet listens on the VZ NAT bridge
# address (Shared_Net_Address, default 192.168.64.1) once an interface holds it.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../qemu/common.sh
. "$HERE/../qemu/common.sh"
# shellcheck source=ssh-opts.sh
. "$HERE/ssh-opts.sh"

SSHD=/usr/sbin/sshd
FIREWALL=/usr/libexec/ApplicationFirewall/socketfilterfw
VMNET_PLIST=/Library/Preferences/SystemConfiguration/com.apple.vmnet.plist

usage() {
	sed -n '4,14p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 64
}

keyfile() { printf '%s/sshd/ssh_host_ed25519_key\n' "$1"; }
pidfile() { printf '%s/pids/sshd.pid\n' "$1"; }

cmd_keygen() {
	local root="${1:-}" k
	lab_check_run_root "$root"
	k="$(keyfile "$root")"
	mkdir -p "$root/sshd"
	if [ ! -f "$k" ]; then
		ssh-keygen -q -t ed25519 -N '' -C "machman-lab-sshd" -f "$k" </dev/null \
			|| lab_die 1 "ssh-keygen failed for $k."
	fi
	printf '%s.pub\n' "$k"
}

cmd_hostkey() {
	local root="${1:-}"
	lab_check_run_root "$root"
	[ -f "$(keyfile "$root").pub" ] || lab_die 1 "no lab sshd host key in $root (sshd.sh keygen)."
	printf '%s.pub\n' "$(keyfile "$root")"
}

cmd_authorize() {
	local root="${1:-}" pub="${2:-}"
	lab_check_run_root "$root"
	[ -f "$pub" ] || lab_die 64 "no public key file at '$pub'."
	mkdir -p "$root/sshd"
	head -n 1 "$pub" >> "$root/sshd/authorized_keys"
	chmod 600 "$root/sshd/authorized_keys"
}

vmnet_address() {
	local a
	a="$(/usr/bin/plutil -extract Shared_Net_Address raw -o - "$VMNET_PLIST" 2>/dev/null)"
	printf '%s\n' "${a:-192.168.64.1}"
}

# 0 when the Application Firewall would prompt for a listener on a reachable address.
firewall_would_prompt() {
	local s
	s="$("$FIREWALL" --getglobalstate --getallowsigned 2>/dev/null)"
	case "$s" in
	*"State = 0"*) return 1 ;;
	esac
	case "$s" in
	*"built-in signed software ENABLED"*) return 1 ;;
	esac
	return 0
}

cmd_doctor() {
	echo "sshd: $("$SSHD" -V 2>&1 | head -n 1)"
	"$FIREWALL" --getglobalstate --getallowsigned 2>&1 | sed 's/^/firewall: /'
	echo "vmnet bridge address: $(vmnet_address)"
	if firewall_would_prompt; then
		echo "doctor: a --bind vmnet sshd would make the firewall prompt: refused"
	else
		echo "doctor: ok"
	fi
}

# is_lab_sshd <pid> <root>: the pid is the sshd serving this root's config (sshd retitles
# itself, so its comm is not "sshd": match the config path on its command line).
is_lab_sshd() {
	ps -p "$1" -o command= 2>/dev/null | grep -qF -- "-f $2/sshd/sshd_config"
}

sshd_pid() { # <root>: the live sshd listener's pid
	local p
	p="$(lab_pid_of "$(pidfile "$1")")" && is_lab_sshd "$p" "$1" && printf '%s\n' "$p"
}

cmd_start() {
	local root="" bind="" port="" password=no home="" wait=30
	while [ $# -gt 0 ]; do
		case "$1" in
		--run) root="${2:-}"; shift 2 ;;
		--bind) bind="${2:-}"; shift 2 ;;
		--port) port="${2:-}"; shift 2 ;;
		--password) password=yes; shift ;;
		--home) home="${2:-}"; shift 2 ;;
		--wait) wait="${2:-}"; shift 2 ;;
		*) usage ;;
		esac
	done
	lab_check_run_root "$root"
	lab_refuse_main_checkout
	[ -n "$home" ] || home="$root/home"
	case "$home" in
	"$root"/*) ;;
	*) lab_die 64 "--home must be inside the run root, not '$home'." ;;
	esac
	if p="$(sshd_pid "$root")"; then
		lab_die 64 "a lab sshd already runs in $root (pid $p)."
	fi
	local addr i
	case "$bind" in
	loopback) addr=127.0.0.1 ;;
	vmnet)
		firewall_would_prompt && lab_die 69 "the firewall would prompt for a bridge listener."
		addr="$(vmnet_address)"
		i=0
		until /sbin/ifconfig 2>/dev/null | grep -q "inet $addr "; do
			[ "$i" -ge "$wait" ] && lab_die 69 "no VZ NAT bridge yet (no interface holds $addr)."
			sleep 1
			i=$((i + 1))
		done ;;
	*) lab_die 64 "--bind is loopback or vmnet, not '$bind'." ;;
	esac
	if [ -z "$port" ]; then
		port="$(lab_free_port)" || lab_die 69 "could not pick a free port."
	fi
	case "$port" in ''|*[!0-9]*) lab_die 64 "--port is a number, not '$port'." ;; esac
	[ "$port" -gt 1024 ] && [ "$port" -lt 65536 ] || lab_die 64 "--port $port is not 1025-65535."
	mkdir -p "$root/sshd" "$root/pids" "$home"
	cmd_keygen "$root" >/dev/null
	local d="$root/sshd" proot ptemp
	proot="$(cd "$root" && pwd -P)"
	ptemp="$(cd "$(getconf DARWIN_USER_TEMP_DIR)" && pwd -P)"
	sed -e "s|@RUN@|$proot|" -e "s|@TEMP@|$ptemp|" "$HERE/session.sb" > "$d/session.sb"
	cp "$HERE/session.sh" "$d/session.sh"
	chmod 755 "$d/session.sh"
	touch "$d/authorized_keys"
	chmod 600 "$d/authorized_keys"
	cat > "$d/sshd_config" <<EOF
# The lab sshd (scripts/lab/sshd/sshd.sh) — everything inside $root.
ListenAddress $addr:$port
HostKey $(keyfile "$root")
PidFile $(pidfile "$root")
AuthorizedKeysFile $home/.ssh/authorized_keys $d/authorized_keys
AllowUsers $(id -un)
StrictModes no
UsePAM no
PasswordAuthentication $password
KbdInteractiveAuthentication no
PermitRootLogin no
PermitEmptyPasswords no
PermitUserRC no
PermitUserEnvironment no
UseDNS no
PrintMotd no
PrintLastLog no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
AllowStreamLocalForwarding no
GatewayPorts no
PermitTunnel no
Subsystem sftp /usr/libexec/sftp-server
ForceCommand $d/session.sh
SetEnv MACHMAN_LAB_HOME=$home MACHMAN_LAB_RUN=$root
LogLevel VERBOSE
EOF
	"$SSHD" -t -f "$d/sshd_config" >"$d/sshd-t.log" 2>&1 \
		|| { sed 's/^/  /' "$d/sshd-t.log" >&2; lab_die 1 "sshd refused its config."; }
	"$SSHD" -f "$d/sshd_config" -E "$d/sshd.log" </dev/null >/dev/null 2>&1 \
		|| lab_die 1 "sshd did not start (see $d/sshd.log)."
	i=0
	until sshd_pid "$root" >/dev/null && nc -z "$addr" "$port" 2>/dev/null; do
		[ "$i" -ge 50 ] && lab_die 1 "sshd is not listening on $addr:$port (see $d/sshd.log)."
		sleep 0.1
		i=$((i + 1))
	done
	echo "$addr:$port" > "$d/address"
	printf '%s:%s\n' "$addr" "$port"
}

cmd_stop() {
	local root="${1:-}" p kids i
	lab_is_run_root "$root" || lab_die 64 "stop takes a run root (/tmp/mml.<token>), not '$root'."
	if p="$(sshd_pid "$root")"; then
		kids="$(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')"
		kill -TERM "$p" 2>/dev/null
		for i in 1 2 3 4 5 6 7 8 9 10; do
			is_lab_sshd "$p" "$root" || break
			sleep 0.2
		done
		is_lab_sshd "$p" "$root" && kill -KILL "$p" 2>/dev/null
		# Sessions outlive the listener: end them (sshd-session and what they run).
		for i in $kids; do
			pkill -TERM -P "$i" 2>/dev/null
			kill -TERM "$i" 2>/dev/null
		done
	fi
	rm -f "$(pidfile "$root")" "$root/sshd/address"
}

# --- self-check ---------------------------------------------------------------------------

self_check() {
	local root fails=0 out rc home key bad_key addr host port realssh before after
	root="$(lab_new_root)"
	SC_ROOT="$root"
	trap '"$HERE/sshd.sh" stop "$SC_ROOT" >/dev/null 2>&1; rm -rf "$SC_ROOT"' EXIT
	ok() { echo "ok    $*"; }
	bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
	home="$root/home"
	mkdir -p "$home"
	key="$root/client/id_ed25519"
	bad_key="$root/client/stranger"
	mkdir -p "$root/client"
	ssh-keygen -q -t ed25519 -N '' -C lab-client -f "$key" </dev/null
	ssh-keygen -q -t ed25519 -N '' -C stranger -f "$bad_key" </dev/null
	realssh="$(eval echo "~$(id -un)")/.ssh"
	listing() { [ -d "$realssh" ] && find "$realssh" -exec stat -f '%N %z %m' {} \; | sort; }
	before="$(listing)"

	"$HERE/sshd.sh" keygen "$root" >/dev/null
	addr="$("$HERE/sshd.sh" start --run "$root" --bind loopback --home "$home")" \
		|| { bad "start"; return 1; }
	host="${addr%:*}"
	port="${addr##*:}"
	"$HERE/sshd.sh" authorize "$root" "$key.pub"
	local user
	user="$(id -un)"
	out="$(lab_ssh "$root" "$key" "$user@$host" "$port" 'echo "$HOME|$(pwd)"' 2>&1)"
	case "$out" in
	"$home|$home"|"$home|/private$home") ok "a session runs in the fake home ($out)" ;;
	*) bad "session home: '$out'" ;;
	esac
	out="$(echo pwd | env -u SSH_AUTH_SOCK sftp -F /dev/null -o IdentityAgent=none \
		-o IdentitiesOnly=yes -i "$key" -o UserKnownHostsFile="$root/ssh/known_hosts" \
		-o GlobalKnownHostsFile=/dev/null -o BatchMode=yes -P "$port" -b - "$user@$host" 2>&1)"
	case "$out" in
	*"Remote working directory: $home"*|*"Remote working directory: /private$home"*)
		ok "sftp starts in the fake home" ;;
	*) bad "sftp: $out" ;;
	esac
	if lab_ssh "$root" "$bad_key" "$user@$host" "$port" true >/dev/null 2>&1; then
		bad "an unauthorized key got in"
	else
		ok "an unauthorized key is refused"
	fi
	methods() { # <port>: the methods sshd offers a key it refuses
		env -u SSH_AUTH_SOCK -u SSH_ASKPASS ssh -F /dev/null -v -o IdentityAgent=none \
			-o IdentitiesOnly=yes -i "$bad_key" -o UserKnownHostsFile="$root/ssh/known_hosts" \
			-o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=accept-new \
			-o BatchMode=yes -o ConnectTimeout=5 -p "$1" "$user@$host" true 2>&1 </dev/null \
			| tr -d '\r' | sed -n 's/.*Authentications that can continue: //p' | head -n 1
	}
	out="$(methods "$port")"
	if [ "$out" = publickey ]; then ok "methods offered: $out"
	else bad "methods offered: '$out' ($(printf '%s' "$out" | od -c | head -n 2))"; fi
	# The probe: a session write outside the sandbox (the lab cache, the user cache dir).
	local probe_dirs="" d f wrote=""
	[ -d "$(lab_cache_dir)" ] && probe_dirs="$(lab_cache_dir)"
	probe_dirs="$probe_dirs $(getconf DARWIN_USER_CACHE_DIR)"
	for d in $probe_dirs; do
		f="$d/.sshd-write-probe-${root##*.}"
		lab_ssh "$root" "$key" "$user@$host" "$port" "echo x > '$f'" >/dev/null 2>&1
		if [ -e "$f" ]; then
			wrote="$wrote $f"
			rm -f "$f"
		fi
	done
	lab_ssh "$root" "$key" "$user@$host" "$port" "echo x > '$home/inside'" >/dev/null 2>&1
	if [ -z "$wrote" ] && [ -f "$home/inside" ]; then
		ok "a session writes inside the sandbox only (refused in:$probe_dirs)"
	else
		bad "a session wrote outside the sandbox:$wrote (inside: $([ -f "$home/inside" ] \
			&& echo yes || echo no))"
	fi
	local pid kids
	pid="$(sshd_pid "$root")"
	"$HERE/sshd.sh" stop "$root"
	sleep 0.5
	kids="$(pgrep -f "sshd-session.*$(id -un)" 2>/dev/null | while read -r k; do
		ps -o ppid= -p "$k" | grep -qw "$pid" && echo "$k"; done)"
	if ! kill -0 "$pid" 2>/dev/null && ! nc -z "$host" "$port" 2>/dev/null && [ -z "$kids" ]; then
		ok "stop frees port $port and leaves no sshd or session"
	else
		bad "after stop: pid $pid alive or port $port busy ($kids)"
	fi
	# --password: offered, and a wrong answer from an askpass is refused (never a real one).
	addr="$("$HERE/sshd.sh" start --run "$root" --bind loopback --home "$home" --password)" \
		|| bad "start --password"
	port="${addr##*:}"
	out="$(methods "$port")"
	if [ "$out" = "publickey,password" ]; then ok "with --password: $out"
	else bad "with --password: '$out'"; fi
	printf '#!/bin/sh\necho wrong\n' > "$root/askpass"
	chmod 755 "$root/askpass"
	if env -u SSH_AUTH_SOCK SSH_ASKPASS="$root/askpass" SSH_ASKPASS_REQUIRE=force \
		ssh -F /dev/null -o IdentityAgent=none -o PubkeyAuthentication=no \
		-o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 \
		-o UserKnownHostsFile="$root/ssh/known_hosts" -o GlobalKnownHostsFile=/dev/null \
		-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -p "$port" "$user@$host" true \
		</dev/null >/dev/null 2>&1; then
		bad "a wrong password got in"
	elif grep -q "Failed password for $user" "$root/sshd/sshd.log"; then
		ok "a wrong password is refused"
	else
		bad "the password attempt never reached sshd"
	fi
	"$HERE/sshd.sh" stop "$root"
	after="$(listing)"
	if [ "$before" = "$after" ]; then
		ok "~/.ssh unchanged ($(printf '%s\n' "$before" | grep -c .) entries)"
	else
		bad "~/.ssh changed"
	fi
	if [ "$fails" = 0 ]; then echo "sshd.sh --self-check: all ok"
	else echo "sshd.sh --self-check: $fails FAILED"; fi
	[ "$fails" = 0 ]
}

case "${1:-}" in
keygen) shift; cmd_keygen "$@" ;;
hostkey) shift; cmd_hostkey "$@" ;;
start) shift; cmd_start "$@" ;;
stop|sweep) shift; cmd_stop "$@" ;;
authorize) shift; cmd_authorize "$@" ;;
doctor) cmd_doctor ;;
--self-check) self_check ;;
*) usage ;;
esac; exit $?
