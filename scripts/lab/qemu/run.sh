#!/bin/bash
# The lab's headless QEMU runner: one aarch64 guest under HVF with edk2, consoles on UNIX
# sockets inside the run sandbox, loopback-only forwards and restricted user networking.
#
#   run.sh start --run <root> --name <n> [--disk <raw>]… [--disk-ro <img>]… [--seed <iso>]
#                [--cpus 1|2] [--mem <MB ≤ 2048>] [--consoles N] [--serial] [--ssh-forward]
#                [--lab-gateway <port>|none] [--net restricted|open] [--owner <pid>]
#                [--firmware-only] [--no-acpi]
#   run.sh stop --run <root> --name <n> [--timeout S]     powerdown, quit, TERM, KILL
#   run.sh status --run <root>
#   run.sh sweep <root>        stop every guest recorded in <root>/pids (the root stays)
#   run.sh --self-check        refusals, a firmware boot, stop, owner watchdog, sweep
#
# Per guest, <root>/qemu/<n>/: vars.fd, serial.sock + serial.log (the PL011), hvc<i>.sock +
# hvc<i>.log (virtconsoles named lab.hvc<i>), qmp.sock, ssh.port, qemu.cmd, qemu.err. Pid files:
# <root>/pids/qemu-<n>.pid (QEMU's own) and <root>/pids/watch-<n>.pid (the owner watchdog).
#
# Host-quiet by construction: -display none -nodefaults -no-user-config (no Cocoa window, no
# Dock icon; there is no passthrough for display flags); hostfwd binds 127.0.0.1 only; every
# test boot has restrict=on (slirp maps 10.0.2.2 to the host's loopback, so an open guest
# could reach the real Remote Login sshd); the guest's lab gateway 10.0.2.100 forwards port 22
# to the lab sshd on 127.0.0.1 (--lab-gateway <port>) or to /usr/bin/true (connects fail at
# once). Open networking (--net open) only for image preparation (MACHMAN_LAB_PREPARE=1).
# The caller holds the lab slot (scripts/lab.sh does; lane-time boots took it by hand).
#
# Refusals exit 64 with one sentence and start nothing; a missing tool exits 69.
set -u
RUNNER_VERSION=1
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

QEMU_COMM=qemu-system-aarch64
LAB_GATEWAY=10.0.2.100
MAX_CPUS=2
MAX_MEM=2048
DISK_OPTS=cache=writeback,discard=unmap

usage() {
	sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 64
}

qemu_bin() {
	command -v "$QEMU_COMM" 2>/dev/null || lab_die 69 "$QEMU_COMM is not installed."
}

firmware_dir() {
	local d
	d="$(cd "$(dirname "$(qemu_bin)")/../share/qemu" 2>/dev/null && pwd)" \
		|| lab_die 69 "no QEMU share dir beside $(qemu_bin)."
	[ -f "$d/edk2-aarch64-code.fd" ] && [ -f "$d/edk2-arm-vars.fd" ] \
		|| lab_die 69 "edk2-aarch64-code.fd or edk2-arm-vars.fd is missing in $d."
	printf '%s\n' "$d"
}

valid_name() {
	case "$1" in
	''|-*|*[!a-z0-9-]*) return 1 ;;
	esac
	[ "${#1}" -le 32 ]
}

guest_dir() { printf '%s/qemu/%s\n' "$1" "$2"; }
pid_file() { printf '%s/pids/qemu-%s.pid\n' "$1" "$2"; }
watch_file() { printf '%s/pids/watch-%s.pid\n' "$1" "$2"; }

# live_guests <root>: how many guest processes (QEMU or a lab vmhost) are alive in <root>.
live_guests() {
	local f p n=0
	for f in "$1"/pids/qemu-*.pid "$1"/pids/vmhost-*.pid; do
		[ -f "$f" ] || continue
		p="$(lab_pid_of "$f")" || continue
		kill -0 "$p" 2>/dev/null && n=$((n + 1))
	done
	echo "$n"
}

realdir() { # <path>: the physical path of an existing file or directory
	if [ -d "$1" ]; then
		(cd "$1" && pwd -P)
	else
		printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"
	fi
}

# kill_guest <pid>: TERM, then KILL after 3 s — only while <pid> is QEMU — and its nc children.
kill_guest() {
	local pid="$1" kids k i
	lab_pid_is "$pid" "$QEMU_COMM" || return 0
	kids="$(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')"
	kill -TERM "$pid" 2>/dev/null
	for i in 1 2 3 4 5 6; do
		lab_pid_is "$pid" "$QEMU_COMM" || break
		sleep 0.5
	done
	lab_pid_is "$pid" "$QEMU_COMM" && kill -KILL "$pid" 2>/dev/null
	for k in $kids; do
		lab_pid_is "$k" nc && kill -TERM "$k" 2>/dev/null
	done
	return 0
}

kill_watchdog() { # <root> <name>
	local wf p
	wf="$(watch_file "$1" "$2")"
	p="$(lab_pid_of "$wf")" && ps -p "$p" -o command= 2>/dev/null | grep -q 'run\.sh _watch' \
		&& kill -TERM "$p" 2>/dev/null
	rm -f "$wf"
}

# sock_opts <guest dir> <base>: a listening console socket that logs everything it carries.
sock_opts() {
	printf 'path=%s/%s.sock,server=on,wait=off,logfile=%s/%s.log' "$1" "$2" "$1" "$2"
}

remove_sockets() { # <guest dir>
	rm -f "$1"/serial.sock "$1"/hvc*.sock "$1"/qmp.sock
}

cmd_start() {
	local root="" name="" seed="" cpus=2 mem=1024 consoles=0 sshfwd=0 gateway=none
	local net=restricted owner="" fwonly=0 noacpi=0
	local -a disks=() ros=()
	while [ $# -gt 0 ]; do
		case "$1" in
		--run) root="${2:-}"; shift 2 ;;
		--name) name="${2:-}"; shift 2 ;;
		--disk) disks+=("${2:-}"); shift 2 ;;
		--disk-ro) ros+=("${2:-}"); shift 2 ;;
		--seed) seed="${2:-}"; shift 2 ;;
		--cpus) cpus="${2:-}"; shift 2 ;;
		--mem) mem="${2:-}"; shift 2 ;;
		--consoles) consoles="${2:-}"; shift 2 ;;
		--serial) shift ;; # the PL011 console is always there; accepted for clarity
		--ssh-forward) sshfwd=1; shift ;;
		--lab-gateway) gateway="${2:-}"; shift 2 ;;
		--net) net="${2:-}"; shift 2 ;;
		--owner) owner="${2:-}"; shift 2 ;;
		--firmware-only) fwonly=1; shift ;;
		--no-acpi) noacpi=1; shift ;;
		*) usage ;;
		esac
	done
	lab_check_run_root "$root"
	lab_refuse_main_checkout
	valid_name "$name" || lab_die 64 "a guest name is 1-32 of a-z, 0-9 and '-', not '$name'."
	case "$cpus" in 1|2) ;; *) lab_die 64 "--cpus is 1 or 2 (the lab's cap), not '$cpus'." ;; esac
	case "$mem" in ''|*[!0-9]*) lab_die 64 "--mem is a number of MB, not '$mem'." ;; esac
	[ "$mem" -ge 128 ] && [ "$mem" -le "$MAX_MEM" ] \
		|| lab_die 64 "--mem is 128-$MAX_MEM MB (the lab's cap), not $mem."
	case "$consoles" in [0-4]) ;; *) lab_die 64 "--consoles is 0-4, not '$consoles'." ;; esac
	case "$net" in
	restricted) ;;
	open) [ "${MACHMAN_LAB_PREPARE:-}" = 1 ] \
		|| lab_die 64 "--net open is for image preparation only (MACHMAN_LAB_PREPARE=1)." ;;
	*) lab_die 64 "--net is restricted or open, not '$net'." ;;
	esac
	case "$gateway" in
	none) ;;
	''|*[!0-9]*) lab_die 64 "--lab-gateway is a port or none, not '$gateway'." ;;
	*) [ "$gateway" -gt 1024 ] && [ "$gateway" -lt 65536 ] \
		|| lab_die 64 "--lab-gateway port $gateway is outside 1025-65535." ;;
	esac
	if [ -n "$owner" ]; then
		case "$owner" in *[!0-9]*) lab_die 64 "--owner is a pid, not '$owner'." ;; esac
		kill -0 "$owner" 2>/dev/null || lab_die 64 "the owner pid $owner is not alive."
	fi
	[ "$fwonly" = 1 ] || [ "${#disks[@]}" -gt 0 ] \
		|| lab_die 64 "start needs --disk (or --firmware-only)."
	local cache f
	cache="$(lab_cache_dir)"
	[ -d "$cache" ] && cache="$(realdir "$cache")"
	for f in ${disks[@]+"${disks[@]}"} ${ros[@]+"${ros[@]}"} ${seed:+"$seed"}; do
		[ -f "$f" ] || lab_die 64 "no disk image at '$f'."
		case "$(realdir "$f")" in
		"$cache"/*) lab_die 64 "$f is in the lab cache: boot an APFS clone (cp -c) of it." ;;
		esac
	done
	local pf
	pf="$(pid_file "$root" "$name")"
	if p="$(lab_pid_of "$pf")" && kill -0 "$p" 2>/dev/null; then
		lab_die 64 "a guest named $name is already running (pid $p)."
	fi
	[ "$(live_guests "$root")" -lt 2 ] \
		|| lab_die 64 "two lab guests are already running in $root (the cap is 2)."

	local qemu fw dir
	qemu="$(qemu_bin)"
	fw="$(firmware_dir)"
	dir="$(guest_dir "$root" "$name")"
	mkdir -p "$dir" "$root/pids"
	remove_sockets "$dir"
	rm -f "$pf" "$dir/ssh.port"
	cp -c "$fw/edk2-arm-vars.fd" "$dir/vars.fd" 2>/dev/null \
		|| cp "$fw/edk2-arm-vars.fd" "$dir/vars.fd"

	local machine="virt,gic-version=3"
	[ "$noacpi" = 1 ] && machine="$machine,acpi=off"
	local mac
	mac="52:54:00:$(printf '%s' "$name" | md5 | sed 's/^\(..\)\(..\)\(..\).*/\1:\2:\3/')"
	local -a argv=("$qemu" -no-user-config -nodefaults -display none -name "lab-$name"
		-machine "$machine" -accel hvf -cpu host -smp "$cpus" -m "$mem"
		-drive "if=pflash,format=raw,readonly=on,file=$fw/edk2-aarch64-code.fd"
		-drive "if=pflash,format=raw,file=$dir/vars.fd"
		-device virtio-rng-pci)
	local i=0
	for f in ${disks[@]+"${disks[@]}"}; do
		argv+=(-drive "if=none,id=disk$i,file=$(realdir "$f"),format=raw,$DISK_OPTS")
		if [ "$i" = 0 ]; then
			argv+=(-device "virtio-blk-pci,drive=disk$i,bootindex=0")
		else
			argv+=(-device "virtio-blk-pci,drive=disk$i")
		fi
		i=$((i + 1))
	done
	i=0
	for f in ${ros[@]+"${ros[@]}"} ${seed:+"$seed"}; do
		argv+=(-drive "if=none,id=ro$i,file=$(realdir "$f"),format=raw,readonly=on"
			-device "virtio-blk-pci,drive=ro$i")
		i=$((i + 1))
	done
	argv+=(-chardev "socket,id=ser0,$(sock_opts "$dir" serial)" -serial chardev:ser0)
	if [ "$consoles" -gt 0 ]; then
		argv+=(-device virtio-serial-pci,id=vser0)
		i=0
		while [ "$i" -lt "$consoles" ]; do
			argv+=(-chardev "socket,id=hvc$i,$(sock_opts "$dir" "hvc$i")"
				-device "virtconsole,bus=vser0.0,chardev=hvc$i,name=lab.hvc$i")
			i=$((i + 1))
		done
	fi
	local restrict=on netdev
	[ "$net" = open ] && restrict=off
	netdev="user,id=n0,restrict=$restrict"
	if [ "$sshfwd" = 1 ]; then
		local port
		port="$(lab_free_port)" || lab_die 69 "could not pick a free port."
		netdev="$netdev,hostfwd=tcp:127.0.0.1:$port-:22"
		echo "$port" > "$dir/ssh.port"
	fi
	if [ "$gateway" = none ]; then
		netdev="$netdev,guestfwd=tcp:$LAB_GATEWAY:22-cmd:/usr/bin/true"
	else
		netdev="$netdev,guestfwd=tcp:$LAB_GATEWAY:22-cmd:/usr/bin/nc 127.0.0.1 $gateway"
	fi
	argv+=(-netdev "$netdev" -device "virtio-net-pci,netdev=n0,mac=$mac"
		-qmp "unix:$dir/qmp.sock,server=on,wait=off" -daemonize -pidfile "$pf")

	printf '%q ' "${argv[@]}" > "$dir/qemu.cmd"
	echo >> "$dir/qemu.cmd"
	if ! "${argv[@]}" </dev/null >"$dir/qemu.err" 2>&1; then
		sed 's/^/  /' "$dir/qemu.err" >&2
		lab_die 1 "QEMU did not start $name (see $dir/qemu.err)."
	fi
	if [ -n "$owner" ]; then
		nohup "$HERE/run.sh" _watch --run "$root" --name "$name" --owner "$owner" \
			</dev/null >/dev/null 2>&1 &
		echo "$!" > "$(watch_file "$root" "$name")"
	fi
	printf '%s\n' "$dir"
}

# _watch: kill the guest once its owner dies (detached; started by start --owner).
cmd_watch() {
	local root="$2" name="$4" owner="$6" pid
	pid="$(lab_pid_of "$(pid_file "$root" "$name")")" || exit 0
	while lab_pid_is "$pid" "$QEMU_COMM"; do
		if ! kill -0 "$owner" 2>/dev/null; then
			kill_guest "$pid"
			remove_sockets "$(guest_dir "$root" "$name")"
			rm -f "$(pid_file "$root" "$name")" "$(watch_file "$root" "$name")"
			exit 0
		fi
		sleep 1
	done
	rm -f "$(watch_file "$root" "$name")"
}

# stop_guest <root> <name> <timeout>
stop_guest() {
	local root="$1" name="$2" timeout="$3" dir pid kids i k
	dir="$(guest_dir "$root" "$name")"
	if pid="$(lab_pid_of "$(pid_file "$root" "$name")")" && lab_pid_is "$pid" "$QEMU_COMM"; then
		kids="$(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')"
		if [ "$timeout" -gt 0 ] && [ -S "$dir/qmp.sock" ]; then
			"$(lab_tool python3)" "$HERE/console.py" "$dir/qmp.sock" qmp system_powerdown \
				--timeout 5 >/dev/null 2>&1
			i=0
			while lab_pid_is "$pid" "$QEMU_COMM" && [ "$i" -lt "$timeout" ]; do
				sleep 1
				i=$((i + 1))
			done
		fi
		if lab_pid_is "$pid" "$QEMU_COMM" && [ -S "$dir/qmp.sock" ]; then
			"$(lab_tool python3)" "$HERE/console.py" "$dir/qmp.sock" qmp quit --timeout 5 \
				>/dev/null 2>&1
			for i in 1 2 3 4 5 6 7 8 9 10; do
				lab_pid_is "$pid" "$QEMU_COMM" || break
				sleep 0.5
			done
		fi
		kill_guest "$pid"
		for k in $kids; do
			lab_pid_is "$k" nc && kill -TERM "$k" 2>/dev/null
		done
	fi
	kill_watchdog "$root" "$name"
	remove_sockets "$dir"
	rm -f "$(pid_file "$root" "$name")"
}

cmd_stop() {
	local root="" name="" timeout=30
	while [ $# -gt 0 ]; do
		case "$1" in
		--run) root="${2:-}"; shift 2 ;;
		--name) name="${2:-}"; shift 2 ;;
		--timeout) timeout="${2:-}"; shift 2 ;;
		*) usage ;;
		esac
	done
	lab_check_run_root "$root"
	valid_name "$name" || lab_die 64 "no guest name '$name'."
	case "$timeout" in ''|*[!0-9]*) lab_die 64 "--timeout is whole seconds." ;; esac
	stop_guest "$root" "$name" "$timeout"
}

cmd_status() {
	local root=""
	[ "${1:-}" = --run ] && root="${2:-}"
	lab_check_run_root "$root"
	local f n p state port
	for f in "$root"/pids/qemu-*.pid; do
		[ -f "$f" ] || continue
		n="${f##*/qemu-}"
		n="${n%.pid}"
		state=stopped
		p="$(lab_pid_of "$f")" && lab_pid_is "$p" "$QEMU_COMM" && state="running pid $p"
		port="$(cat "$root/qemu/$n/ssh.port" 2>/dev/null)"
		echo "$n $state${port:+ ssh 127.0.0.1:$port}"
	done
}

cmd_sweep() {
	local root="${1:-}" f n
	lab_is_run_root "$root" || lab_die 64 "sweep takes a run root (/tmp/mml.<token>), not '$root'."
	[ -d "$root/pids" ] || return 0
	for f in "$root"/pids/qemu-*.pid "$root"/pids/watch-*.pid; do
		[ -f "$f" ] || continue
		n="${f##*/}"
		n="${n#qemu-}"
		n="${n#watch-}"
		stop_guest "$root" "${n%.pid}" 0
	done
}

# --- self-check ---------------------------------------------------------------------------

self_check() {
	local root fails=0 py out rc dir pid owner t
	py="$(lab_tool python3)"
	qemu_bin >/dev/null
	root="$(lab_new_root)"
	SC_ROOT="$root"
	trap 'cmd_sweep "$SC_ROOT" >/dev/null 2>&1; rm -rf "$SC_ROOT"' EXIT
	ok() { echo "ok    $*"; }
	bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
	refused() { # <label> <run.sh args…> — exits 64 and starts nothing
		local label="$1"
		shift
		out="$("$@" 2>&1)"
		rc=$?
		if [ "$rc" = 64 ] && ! pgrep -f "lab-sc-" >/dev/null && [ ! -d "$root/qemu/sc-x" ]; then
			ok "refused: $label ($out)"
		else
			bad "refused: $label: exit $rc, $out"
		fi
	}
	local me="$HERE/run.sh"
	mkdir -p "$root/cache" "$root/pids"
	: > "$root/disk.raw"
	: > "$root/cache/cached.raw"
	refused "a run root outside /tmp/mml.*" \
		"$me" start --run /tmp/not-a-lab --name sc-x --firmware-only
	refused "3 vCPUs" "$me" start --run "$root" --name sc-x --cpus 3 --firmware-only
	refused "4096 MB" "$me" start --run "$root" --name sc-x --mem 4096 --firmware-only
	refused "a disk in the lab cache" env MACHMAN_LAB_CACHE="$root/cache" \
		"$me" start --run "$root" --name sc-x --disk "$root/cache/cached.raw"
	refused "open networking outside preparation" env -u MACHMAN_LAB_PREPARE \
		"$me" start --run "$root" --name sc-x --net open --firmware-only
	sleep 300 & local s1=$!
	sleep 300 & local s2=$!
	echo "$s1" > "$root/pids/qemu-sc-a.pid"
	echo "$s2" > "$root/pids/vmhost-sc-b.pid"
	refused "a third live guest" "$me" start --run "$root" --name sc-x --firmware-only
	kill "$s1" "$s2" 2>/dev/null
	wait "$s1" "$s2" 2>/dev/null
	rm -f "$root/pids/qemu-sc-a.pid" "$root/pids/vmhost-sc-b.pid"
	# The main checkout: a copy of the scripts inside a fresh repository whose .git is its own.
	local fake="$root/fake"
	mkdir -p "$fake/scripts/lab/qemu"
	cp "$HERE/run.sh" "$HERE/common.sh" "$HERE/console.py" "$fake/scripts/lab/qemu/"
	"$(lab_tool git)" -C "$fake" init -q >/dev/null 2>&1
	refused "the main checkout" "$fake/scripts/lab/qemu/run.sh" start --run "$root" \
		--name sc-x --firmware-only

	# (b) a firmware-only boot reaches the UEFI shell on the serial socket; loopback forward.
	dir="$("$me" start --run "$root" --name sc-fw --firmware-only --cpus 1 --mem 512 \
		--consoles 1 --ssh-forward)" || bad "start sc-fw"
	if out="$("$py" "$HERE/console.py" "$dir/serial.sock" --transcript "$dir/serial.transcript" \
		expect 'UEFI|Shell>' --nudge 10 --timeout 60 2>&1)"; then
		ok "edk2 reached '$out' on serial.sock"
	else
		bad "no UEFI banner on serial.sock: $out"
	fi
	local port listen
	port="$(cat "$dir/ssh.port" 2>/dev/null)"
	listen="$(lsof -nP -a -p "$(lab_pid_of "$(pid_file "$root" sc-fw)")" -iTCP -sTCP:LISTEN \
		2>/dev/null | awk 'NR > 1 { print $9 }' | sort -u | tr '\n' ' ')"
	if [ "$listen" = "127.0.0.1:$port " ]; then
		ok "the ssh forward listens on 127.0.0.1:$port only"
	else
		bad "listening sockets: '$listen' (want 127.0.0.1:$port)"
	fi
	if grep -q -- '-display none' "$dir/qemu.cmd" && grep -q 'restrict=on' "$dir/qemu.cmd" \
		&& grep -q -- '-nodefaults' "$dir/qemu.cmd"; then
		ok "headless and restricted (-display none -nodefaults, restrict=on)"
	else
		bad "qemu.cmd lacks -display none / -nodefaults / restrict=on"
	fi
	# (c) stop leaves no QEMU and no sockets.
	pid="$(lab_pid_of "$(pid_file "$root" sc-fw)")"
	"$me" stop --run "$root" --name sc-fw --timeout 2
	if ! kill -0 "$pid" 2>/dev/null && [ -z "$(ls "$dir"/*.sock 2>/dev/null)" ]; then
		ok "stop: no QEMU pid, no sockets"
	else
		bad "stop left pid $pid or sockets: $(ls "$dir" | tr '\n' ' ')"
	fi
	# (d) the owner dies: the watchdog kills QEMU within 5 s.
	sleep 300 &
	owner=$!
	dir="$("$me" start --run "$root" --name sc-owned --firmware-only --cpus 1 --mem 512 \
		--owner "$owner")" || bad "start sc-owned"
	pid="$(lab_pid_of "$(pid_file "$root" sc-owned)")"
	kill "$owner"
	wait "$owner" 2>/dev/null
	t=0
	while kill -0 "$pid" 2>/dev/null && [ "$t" -lt 10 ]; do sleep 0.5; t=$((t + 1)); done
	if ! kill -0 "$pid" 2>/dev/null; then
		ok "the owner died: QEMU gone within $((t / 2)).$((t % 2 * 5)) s"
	else
		bad "QEMU $pid outlived its owner by 5 s"
	fi
	# (e) a guest whose owner and watchdog are both gone: sweep stops it.
	sleep 300 &
	owner=$!
	dir="$("$me" start --run "$root" --name sc-orphan --firmware-only --cpus 1 --mem 512 \
		--owner "$owner")" || bad "start sc-orphan"
	pid="$(lab_pid_of "$(pid_file "$root" sc-orphan)")"
	kill -KILL "$(lab_pid_of "$(watch_file "$root" sc-orphan)")" 2>/dev/null
	kill "$owner"
	wait "$owner" 2>/dev/null
	sleep 1
	if kill -0 "$pid" 2>/dev/null; then
		"$me" sweep "$root"
		if ! kill -0 "$pid" 2>/dev/null && [ -z "$(ls "$dir"/*.sock 2>/dev/null)" ] \
			&& [ -z "$(ls "$root"/pids/ 2>/dev/null)" ]; then
			ok "sweep stopped the orphaned guest and cleared its pid files"
		else
			bad "sweep left pid $pid, sockets or pid files"
		fi
	else
		bad "the orphaned guest died before the sweep (the watchdog was killed first)"
	fi
	if pgrep -f "lab-sc-" >/dev/null; then bad "a self-check QEMU is still running"; fi
	if [ "$fails" = 0 ]; then echo "run.sh --self-check: all ok"
	else echo "run.sh --self-check: $fails FAILED"; fi
	[ "$fails" = 0 ]
}

case "${1:-}" in
start) shift; cmd_start "$@" ;;
stop) shift; cmd_stop "$@" ;;
status) shift; cmd_status "$@" ;;
sweep) shift; cmd_sweep "$@" ;;
_watch) shift; cmd_watch "$@" ;;
--self-check) self_check ;;
--help|-h) usage ;;
*) usage ;;
esac
