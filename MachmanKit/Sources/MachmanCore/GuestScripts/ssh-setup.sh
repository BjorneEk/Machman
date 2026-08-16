#!/bin/sh
# Machman SSH setup. Do not edit: Machman regenerates this file at every VM start.
#
# Enables this guest's SSH server and installs the Machman host's public key for
# the invoking user. --two-way additionally prepares guest→host SSH (the host side
# still requires your approval in Machman). Safe to re-run at any time;
# --uninstall removes everything it installed (the SSH server stays enabled).
set -eu

SCRIPT_VERSION=1

PAYLOAD_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ ! -r "$PAYLOAD_DIR/machman.env" ]; then
	echo "machman.env is missing next to this script — run the copy Machman put in" >&2
	echo "the share, not install.sh on its own." >&2
	exit 1
fi
# VM_NAME, MARKER, REPORT_DIR_NAME, HOST_USER, HOST_NAME, HOST_LOCAL
. "$PAYLOAD_DIR/machman.env"
REPORT_DIR="$PAYLOAD_DIR/../$REPORT_DIR_NAME"

usage() {
	echo "usage: sh \"$0\" [--two-way | --one-way] [--install] [--user <name>]" >&2
	echo "       sh \"$0\" --uninstall [--user <name>]" >&2
	exit 64
}

TWO_WAY=""
DO_INSTALL=""
UNINSTALL=""
USER_OVERRIDE=""
while [ $# -gt 0 ]; do
	case "$1" in
	--two-way) TWO_WAY=1 ;;
	--one-way) TWO_WAY=0 ;;
	--install) DO_INSTALL=1 ;;
	--uninstall) UNINSTALL=1 ;;
	--user)
		shift
		[ $# -gt 0 ] || usage
		USER_OVERRIDE="$1"
		;;
	*) usage ;;
	esac
	shift
done

if [ "$(id -u)" -ne 0 ]; then
	echo "Please run as root (sudo sh \"$0\" …, or from a root shell)." >&2
	exit 1
fi

# ----- who asked --------------------------------------------------------------
OS="$(uname -s)"
U="${USER_OVERRIDE:-${SUDO_USER:-}}"
if [ "$OS" = "Darwin" ] && { [ -z "$U" ] || [ "$U" = "root" ]; }; then
	U="$(echo "show State:/Users/ConsoleUser" | scutil \
		| awk '/Name :/ && ! /loginwindow/ { print $3 }')"
fi
if [ -z "$U" ] || [ "$U" = "root" ]; then
	# Root consoles (Alpine, FreeBSD) have no sudo and no SUDO_USER.
	echo "Cannot tell which user to set up — name one:  sh \"$0\" --user <name>" >&2
	candidates="$(awk -F: '$3 >= 1000 && $7 !~ /(nologin|false)$/ { print "  "$1 }' \
		/etc/passwd 2>/dev/null || true)"
	if [ -n "$candidates" ]; then
		echo "Users on this guest:" >&2
		echo "$candidates" >&2
	fi
	exit 1
fi
case "$OS" in
Darwin)
	HOME_DIR="$(dscl . -read "/Users/$U" NFSHomeDirectory | awk '{print $2}')"
	;;
*)
	HOME_DIR="$(getent passwd "$U" 2>/dev/null | cut -d: -f6 || true)"
	[ -n "$HOME_DIR" ] || HOME_DIR="$(eval echo "~$U")"
	;;
esac
GROUP="$(id -gn "$U")"

# ----- which guest ------------------------------------------------------------
ID=""
ID_LIKE=""
if [ "$OS" = "Linux" ] && [ -r /etc/os-release ]; then
	. /etc/os-release
fi
ID_ALL="$ID $ID_LIKE"
has_word() {
	case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
FAMILY=""
OS_ID=""
if [ "$OS" = "Darwin" ]; then FAMILY="darwin"; OS_ID="darwin"
elif [ "$OS" = "FreeBSD" ]; then FAMILY="freebsd"; OS_ID="freebsd"
elif [ "$ID" = "nixos" ]; then FAMILY="nixos"; OS_ID="$ID"
elif [ "$ID" = "alpine" ]; then FAMILY="alpine"; OS_ID="$ID"
elif has_word debian "$ID_ALL"; then FAMILY="debian"; OS_ID="$ID"
elif has_word arch "$ID_ALL"; then FAMILY="arch"; OS_ID="$ID"
elif has_word rhel "$ID_ALL" || has_word fedora "$ID_ALL" \
	|| has_word centos "$ID_ALL"; then FAMILY="rhel"; OS_ID="$ID"
elif has_word suse "$ID_ALL" || has_word opensuse "$ID_ALL"; then
	FAMILY="suse"; OS_ID="$ID"
elif [ "$OS" = "Linux" ]; then FAMILY="linux-other"; OS_ID="${ID:-linux}"
else
	echo "Unsupported guest OS: $OS" >&2
	exit 1
fi
# systemd-as-PID-1 test (sd_booted): NOT command -v systemctl — Devuan has apt
# without systemd.
SYSTEMD=""
[ -d /run/systemd/system ] && SYSTEMD=1

# ----- helpers ----------------------------------------------------------------
strip_block() {
	[ -f "$1" ] || return 0
	tmp="$1.machman-tmp"
	awk -v m="$MARKER" '
		$0 == "# BEGIN " m { skip = 1; next }
		$0 == "# END " m { skip = 0; next }
		!skip { print }
	' "$1" > "$tmp"
	mv "$tmp" "$1"
}

GATEWAY=""
IP=""
find_addresses() {
	case "$OS" in
	Darwin|FreeBSD)
		GATEWAY="$(route -n get default 2>/dev/null \
			| awk '/gateway:/{print $2; exit}' || true)"
		IF="$(route -n get default 2>/dev/null \
			| awk '/interface:/{print $2; exit}' || true)"
		if [ "$OS" = "Darwin" ] && [ -n "$IF" ]; then
			IP="$(ipconfig getifaddr "$IF" 2>/dev/null || true)"
		elif [ -n "$IF" ]; then
			IP="$(ifconfig "$IF" 2>/dev/null \
				| awk '/inet /{print $2; exit}' || true)"
		fi
		;;
	Linux)
		GATEWAY="$(ip route show default 2>/dev/null | awk \
			'{for(i=1;i<NF;i++) if($i=="via"){print $(i+1); exit}}' || true)"
		if [ -n "$GATEWAY" ]; then
			IP="$(ip route get "$GATEWAY" 2>/dev/null | awk \
				'{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
		fi
		;;
	esac
}

GUEST_HOST_KEY=""
REVERSE_PUBKEY=""
write_report() {
	if [ ! -d "$REPORT_DIR" ] || [ ! -w "$REPORT_DIR" ]; then
		echo "warning: cannot write the report back to Machman — the app will" \
			"not learn this guest's address" >&2
		return 0
	fi
	{
		printf 'SCRIPT_VERSION=%s\n' "$SCRIPT_VERSION"
		printf 'MARKER=%s\n' "$MARKER"
		printf 'OS_ID=%s\n' "$OS_ID"
		printf 'USER=%s\n' "$U"
		printf 'HOME=%s\n' "$HOME_DIR"
		printf 'HOSTNAME=%s\n' "$(hostname 2>/dev/null || true)"
		printf 'IP=%s\n' "$IP"
		printf 'GATEWAY=%s\n' "$GATEWAY"
		printf 'TWO_WAY=%s\n' "${TWO_WAY:-0}"
		[ -n "$GUEST_HOST_KEY" ] && printf 'HOST_KEY=%s\n' "$GUEST_HOST_KEY"
		[ -n "$REVERSE_PUBKEY" ] && printf 'REVERSE_PUBKEY=%s\n' "$REVERSE_PUBKEY"
		[ -n "${1:-}" ] && printf 'UNINSTALLED=1\n'
		:
	} > "$REPORT_DIR/report.env.tmp"
	mv "$REPORT_DIR/report.env.tmp" "$REPORT_DIR/report.env"
}

# ----- uninstall --------------------------------------------------------------
if [ -n "$UNINSTALL" ]; then
	ak="$HOME_DIR/.ssh/authorized_keys"
	if [ -f "$ak" ]; then
		tmp="$ak.machman-tmp"
		grep -vF "$MARKER" "$ak" > "$tmp" || true
		mv "$tmp" "$ak"
		chown "$U:$GROUP" "$ak"
		chmod 600 "$ak"
	fi
	[ -f "$HOME_DIR/.ssh/config" ] && strip_block "$HOME_DIR/.ssh/config"
	rm -f "$HOME_DIR/.ssh/machman_host" "$HOME_DIR/.ssh/machman_host.pub" \
		"$HOME_DIR/.ssh/machman_known_hosts"
	if [ "$FAMILY" = "nixos" ] && [ -f /etc/nixos/configuration.nix ] \
		&& grep -q "# $MARKER" /etc/nixos/configuration.nix; then
		tmp="/etc/nixos/configuration.nix.machman-tmp"
		grep -v "# $MARKER" /etc/nixos/configuration.nix > "$tmp"
		mv "$tmp" /etc/nixos/configuration.nix
		echo "removed the Machman line from configuration.nix — run" \
			"'sudo nixos-rebuild switch' to apply."
	fi
	find_addresses
	write_report uninstalled
	echo "done — Machman's SSH artifacts removed. The SSH server itself was left"
	echo "enabled; disable it yourself if you no longer want it."
	exit 0
fi

# ----- one-way or two-way? ----------------------------------------------------
if [ -z "$TWO_WAY" ]; then
	if [ -t 0 ]; then
		printf "Also set up guest → host SSH back to the Mac? [y/N] "
		read -r answer || answer=""
		case "$answer" in
		y|Y|yes|YES) TWO_WAY=1 ;;
		*) TWO_WAY=0 ;;
		esac
	else
		TWO_WAY=0
	fi
fi

# ----- enable sshd ------------------------------------------------------------
ensure_sshd_installed() {
	if command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ]; then
		return 0
	fi
	if [ -n "$DO_INSTALL" ]; then
		echo "installing the SSH server:  $1"
		$1
	else
		echo "The SSH server is not installed. Install it first:" >&2
		echo "    sudo $1" >&2
		echo "(or re-run this script with --install to let it do that)" >&2
		exit 1
	fi
}

case "$FAMILY" in
darwin)
	# The systemsetup remote-login toggle is Full-Disk-Access-gated and FAILS in
	# a fresh VM; launchd control is not TCC-gated and persists across boots.
	if ! launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
		launchctl enable system/com.openssh.sshd
		launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist \
			2>/dev/null || true
	fi
	# macOS mints host keys at the first CONNECTION — create them now instead.
	[ -f /etc/ssh/ssh_host_ed25519_key.pub ] || ssh-keygen -A
	;;
freebsd)
	sysrc sshd_enable=YES >/dev/null
	service sshd start >/dev/null 2>&1 || service sshd restart >/dev/null 2>&1 || true
	;;
alpine)
	ensure_sshd_installed "apk add openssh"
	rc-update add sshd default >/dev/null 2>&1 || true
	rc-service sshd start >/dev/null 2>&1 \
		|| rc-service sshd restart >/dev/null 2>&1 || true
	;;
nixos)
	# Post-rebuild re-runs: once sshd is active there is nothing to say.
	if systemctl is-active sshd >/dev/null 2>&1; then
		echo "sshd is already enabled (declaratively) — nothing to change."
	elif [ -n "$DO_INSTALL" ] && [ -f /etc/nixos/configuration.nix ] \
		&& ! grep -q "services.openssh" /etc/nixos/configuration.nix; then
		# --install: append one marked line inside the final brace, then
		# rebuild. Backed up first; flake systems (no configuration.nix in
		# charge) or existing openssh config fall through to the manual steps.
		cp /etc/nixos/configuration.nix /etc/nixos/configuration.nix.machman-backup
		awk -v m="$MARKER" '
			{ lines[NR] = $0 }
			END {
				for (i = NR; i >= 1; i--) {
					if (lines[i] ~ /^}/) {
						lines[i] = "  services.openssh.enable = true; # " m \
							"\n" lines[i]
						break
					}
				}
				for (i = 1; i <= NR; i++) print lines[i]
			}
		' /etc/nixos/configuration.nix.machman-backup > /etc/nixos/configuration.nix
		echo "enabled services.openssh in configuration.nix — rebuilding (slow)…"
		nixos-rebuild switch
	else
		cat <<'NIXOS'
NixOS is declarative — enable sshd yourself (or re-run with --install and this
script edits configuration.nix and rebuilds for you):

  1. add to /etc/nixos/configuration.nix:   services.openssh.enable = true;
  2. apply it:                              sudo nixos-rebuild switch
  3. re-run this script

Your key is already installed either way (honored once sshd is up).
NIXOS
	fi
	;;
debian|arch|rhel|suse|linux-other)
	case "$FAMILY" in
	debian) ensure_sshd_installed "apt-get install -y openssh-server" ;;
	arch) ensure_sshd_installed "pacman -S --noconfirm openssh" ;;
	rhel) ensure_sshd_installed "dnf install -y openssh-server" ;;
	suse) ensure_sshd_installed "zypper install -y openssh" ;;
	esac
	unit="sshd"
	[ "$FAMILY" = "debian" ] && unit="ssh"
	if [ -n "$SYSTEMD" ]; then
		systemctl enable --now "$unit"
	else
		echo "warning: no systemd — enable the '$unit' service with your init" \
			"system yourself" >&2
	fi
	if [ "$FAMILY" = "suse" ] && command -v firewall-cmd >/dev/null 2>&1; then
		# openSUSE's firewall blocks port 22 by default on desktop roles.
		firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
		firewall-cmd --reload >/dev/null 2>&1 || true
	fi
	;;
esac

# ----- install the host's key ---------------------------------------------------
key="$(cat "$PAYLOAD_DIR/host_key.pub")"
mkdir -p "$HOME_DIR/.ssh"
touch "$HOME_DIR/.ssh/authorized_keys"
if ! grep -qF "$key" "$HOME_DIR/.ssh/authorized_keys"; then
	printf '%s\n' "$key" >> "$HOME_DIR/.ssh/authorized_keys"
fi
chown "$U:$GROUP" "$HOME_DIR/.ssh" "$HOME_DIR/.ssh/authorized_keys"
chmod 700 "$HOME_DIR/.ssh"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
# SELinux (rhel-family, Leap 16): a root-written authorized_keys can land with the
# wrong context and be silently refused — exactly what ssh-copy-id fixes up.
if command -v restorecon >/dev/null 2>&1; then
	restorecon -R "$HOME_DIR/.ssh" 2>/dev/null || true
fi

# ----- collect facts ------------------------------------------------------------
find_addresses
if [ "$FAMILY" != "nixos" ] && [ ! -r /etc/ssh/ssh_host_ed25519_key.pub ]; then
	ssh-keygen -A 2>/dev/null || true
fi
if [ -r /etc/ssh/ssh_host_ed25519_key.pub ]; then
	GUEST_HOST_KEY="$(cat /etc/ssh/ssh_host_ed25519_key.pub)"
fi

# ----- guest → host (two-way) ---------------------------------------------------
if [ "$TWO_WAY" = "1" ]; then
	sshdir="$HOME_DIR/.ssh"
	keyfile="$sshdir/machman_host"
	if [ ! -f "$keyfile" ]; then
		ssh-keygen -q -t ed25519 -N "" -C "$MARKER-reverse" -f "$keyfile"
	fi
	REVERSE_PUBKEY="$(cat "$keyfile.pub")"
	host_target="$GATEWAY"
	if [ "$OS" = "Darwin" ] && [ -n "$HOST_LOCAL" ]; then
		# Bonjour name survives NAT-subnet renumbering; macOS guests resolve it.
		host_target="$HOST_LOCAL"
	fi
	# Pin the Mac's host key so the first guest→host connect has no TOFU prompt.
	known=""
	if [ -r "$PAYLOAD_DIR/host_machine_key.pub" ] && [ -n "$host_target" ]; then
		hk="$(awk '{print $1" "$2}' "$PAYLOAD_DIR/host_machine_key.pub")"
		known="$sshdir/machman_known_hosts"
		{
			[ -n "$GATEWAY" ] && printf '%s %s\n' "$GATEWAY" "$hk"
			[ -n "$HOST_LOCAL" ] && printf '%s %s\n' "$HOST_LOCAL" "$hk"
			:
		} > "$known"
		chown "$U:$GROUP" "$known"
		chmod 600 "$known"
	fi
	if [ -n "$host_target" ]; then
		config="$sshdir/config"
		touch "$config"
		strip_block "$config"
		{
			printf '# BEGIN %s\n' "$MARKER"
			printf 'Host mac\n'
			printf '\tHostName %s\n' "$host_target"
			printf '\tUser %s\n' "$HOST_USER"
			printf '\tIdentityFile %s\n' "$keyfile"
			printf '\tIdentitiesOnly yes\n'
			[ -n "$known" ] && printf '\tUserKnownHostsFile %s\n' "$known"
			printf '# END %s\n' "$MARKER"
		} > "$config.machman-block"
		cat "$config.machman-block" >> "$config"
		rm -f "$config.machman-block"
		chown "$U:$GROUP" "$config"
		chmod 600 "$config"
		echo "guest → host: 'ssh mac' (as $U — other users, root included, are" \
			"not configured) reaches $host_target once you approve this VM in" \
			"Machman and the Mac's Remote Login is on."
	else
		echo "warning: no route to the host found — guest → host config skipped" >&2
	fi
	chown "$U:$GROUP" "$keyfile" "$keyfile.pub"
	chmod 600 "$keyfile"
fi

# ----- report back --------------------------------------------------------------
write_report

echo ""
echo "done — SSH is set up for $U."
if [ -n "$IP" ]; then
	echo "From your Mac:    ssh $U@$IP"
fi
echo "Machman shows this VM's live address in the Network device's inspector."
