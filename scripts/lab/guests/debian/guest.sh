#!/bin/bash
# Debian lab guests under QEMU: boot a prepared debian / debian-sysv image and check it.
#
#   guest.sh boot debian|debian-sysv --run <root> [--name N] [--lab-gateway <port>|none]
#                [--consoles N] [--owner PID] [--cache D] [--image <prepared raw>]
#                                         prints the guest dir (3 virtconsoles by default)
#   guest.sh check debian|debian-sysv [--run <root>] [--cache D]
#             boot; PID 1, sshfs and nft, hvc0-2, a root login on the driver console hvc2
#   guest.sh lab-route                    the command that sends the default route to the lab
#                                         gateway (QEMU)
#   guest.sh lab-redirect <gw> <port>     the nft commands that send <gw>:22 to the lab sshd on
#                                         <gw>:<port> (VZ guests, whose gateway is the bridge)
#   guest.sh lab-isolate                  a script that closes a VZ guest's network from the
#                                         inside: nothing but DHCP leaves it, now and at every
#                                         boot (QEMU's restrict=on for a guest on VZ NAT, whose
#                                         gateway is this Mac and its real sshd)
#
# root logs in over ssh with the image's baked key; on a console with an empty password.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../qemu/guest-lib.sh
. "$HERE/../../qemu/guest-lib.sh"

ROUTE="ip route replace default via $GUEST_LAB_GATEWAY"

usage() {
	sed -n '4,17p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 64
}

guest_of() {
	case "${1:-}" in
	debian|debian-sysv) echo "$1" ;;
	*) lab_die 64 "the Debian guest is debian or debian-sysv, not '${1:-}'." ;;
	esac
}

boot() { # <guest> <args…>: three virtconsoles unless asked otherwise
	local g="$1"
	shift
	case " $* " in
	*" --consoles "*) guest_boot "$g" root "$ROUTE" "$@" ;;
	*) guest_boot "$g" root "$ROUTE" --consoles 3 "$@" ;;
	esac
}

cmd_check() {
	local guest="$1" run="" cache=""
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--run) run="${2:-}"; shift 2 ;;
		--cache) cache="${2:-}"; shift 2 ;;
		*) usage ;;
		esac
	done
	if [ -z "$run" ]; then
		# It boots QEMU: inside a lab run (the slot), its own unless one is running already.
		lab_in_run || { lab_session "$HERE/guest.sh" check "$guest" ${cache:+--cache "$cache"}
			return $?; }
		run="$MACHMAN_LAB_RUN"
	fi
	CHECK_RUN="$run" CHECK_NAME="chk-$guest"
	trap '"$LAB_QEMU_DIR/run.sh" stop --run "$CHECK_RUN" --name "$CHECK_NAME" --timeout 0 \
		>/dev/null 2>&1' EXIT
	local d py out pid1 fails="" t0 login
	d="$(boot "$guest" --run "$run" --name "chk-$guest" --owner $$ ${cache:+--cache "$cache"})" \
		|| exit $?
	py="$(lab_tool python3)"
	out="$(guest_ssh "$d" 'ps -o comm= -p 1; command -v sshfs nft; ls /dev/hvc0 /dev/hvc1 \
/dev/hvc2; test -e /run/systemd/system && echo systemd-run-dir')"
	pid1="$(printf '%s\n' "$out" | head -n 1)"
	case "$guest:$pid1" in
	debian:systemd|debian-sysv:init) ;;
	*) fails="$fails pid1=$pid1" ;;
	esac
	for want in /sshfs /nft /dev/hvc0 /dev/hvc1 /dev/hvc2; do
		printf '%s\n' "$out" | grep -q "$want\$" || fails="$fails missing:$want"
	done
	if [ "$guest" = debian-sysv ] && printf '%s\n' "$out" | grep -q systemd-run-dir; then
		fails="$fails /run/systemd/system"
	fi
	t0="$(date +%s)"
	if "$py" "$LAB_QEMU_DIR/console.py" "$d/hvc2.sock" --transcript "$d/hvc2.transcript" \
		login --user root --nudge 3 --timeout 60 \
		&& [ "$("$py" "$LAB_QEMU_DIR/console.py" "$d/hvc2.sock" run --timeout 20 -- tty)" \
			= /dev/hvc2 ]; then
		"$py" "$LAB_QEMU_DIR/console.py" "$d/hvc2.sock" send exit
	else
		fails="$fails hvc2-login"
	fi
	login=$(( $(date +%s) - t0 ))
	# shellcheck source=/dev/null
	. "$d/guest.env"
	"$LAB_QEMU_DIR/run.sh" stop --run "$run" --name "chk-$guest" --timeout 0
	if [ -n "$fails" ]; then
		echo "$guest: FAILED:$fails (see $d)"
		return 1
	fi
	if [ "$guest" = debian ]; then
		echo "debian: pid1=systemd sshfs nft hvc0-2 ok, root on hvc2 (boot" \
			"$GUEST_BOOT_SECONDS s, console login $login s)"
	else
		echo "debian-sysv: pid1=init, no /run/systemd/system, sshfs nft hvc0-2 ok, root on" \
			"hvc2 (boot $GUEST_BOOT_SECONDS s, console login $login s)"
	fi
}

cmd_redirect() { # <gateway> <port>
	local gw="${1:-}" port="${2:-}"
	case "$gw" in *[!0-9.]*|'') lab_die 64 "lab-redirect takes an IPv4 gateway, not '$gw'." ;; esac
	case "$port" in *[!0-9]*|'') lab_die 64 "lab-redirect takes a port, not '$port'." ;; esac
	cat <<EOF
nft add table ip machman_lab
nft add chain ip machman_lab out '{ type nat hook output priority -100; }'
nft add rule ip machman_lab out ip daddr $gw tcp dport 22 dnat to $gw:$port
EOF
}

# cmd_isolate: the script (run as root in the guest) that loads the restricted ruleset and
# persists it: systemd's nftables.service (before network-pre.target) or, under sysvinit,
# an ifupdown pre-up hook. It prints "lab-isolate: ok" once the table is loaded.
cmd_isolate() {
	cat <<'EOF'
#!/bin/sh
# The lab's restricted network for a VZ guest (scripts/lab/guests/debian/guest.sh lab-isolate):
# nothing leaves the guest but DHCP; TCP is reset, the rest refused, at once.
set -e
cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
flush ruleset
table inet machman_lab {
	chain out {
		type filter hook output priority 0; policy accept;
		oif "lo" accept
		udp dport 67 accept
		meta l4proto tcp reject with tcp reset
		reject
	}
}
NFT
nft -f /etc/nftables.conf
if [ -d /run/systemd/system ]; then
	systemctl enable nftables.service >/dev/null 2>&1
else
	mkdir -p /etc/network/if-pre-up.d
	printf '#!/bin/sh\n%s\n' \
		'nft list table inet machman_lab >/dev/null 2>&1 || nft -f /etc/nftables.conf' \
		> /etc/network/if-pre-up.d/machman-lab
	chmod 755 /etc/network/if-pre-up.d/machman-lab
fi
nft list table inet machman_lab >/dev/null
echo "lab-isolate: ok"
EOF
}

case "${1:-}" in
boot) shift; g="$(guest_of "${1:-}")" || exit $?; shift; boot "$g" "$@" ;;
check) shift; g="$(guest_of "${1:-}")" || exit $?; shift; cmd_check "$g" "$@" ;;
lab-route) echo "$ROUTE" ;;
lab-redirect) shift; cmd_redirect "$@" ;;
lab-isolate) cmd_isolate ;;
*) usage ;;
esac; exit $?
