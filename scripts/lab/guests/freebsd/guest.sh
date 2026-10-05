#!/bin/bash
# FreeBSD lab guests under QEMU: boot a prepared freebsd14/freebsd15 image and check it.
#
#   guest.sh boot 14|15 --run <root> [--name N] [--lab-gateway <port>|none] [--consoles N]
#                [--owner PID] [--cache D] [--image <prepared raw>]     prints the guest dir
#   guest.sh check 14|15 [--run <root>] [--cache D]
#             boot, log in as root on the serial console (no password), ssh as lab with the
#             baked key, doas, fusefs-sshfs; stop; print the timings
#   guest.sh lab-route     the command that sends the guest's default route to the lab gateway
#
# 14 and 15 also go by their guest names (freebsd14, freebsd15). Per-run boots take no seed
# (the key is baked into the prepared image) and have restricted networking; the lab gateway
# 10.0.2.100 replaces the default route, so the guest's "Mac" is the lab sshd
# (--lab-gateway <port>) or nothing.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../qemu/guest-lib.sh
. "$HERE/../../qemu/guest-lib.sh"

ROUTE="doas route -q change default $GUEST_LAB_GATEWAY"
ROUTE="$ROUTE || doas route -q add default $GUEST_LAB_GATEWAY"

usage() {
	sed -n '4,10p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 64
}

guest_of() {
	case "${1:-}" in
	14|freebsd14) echo freebsd14 ;;
	15|freebsd15) echo freebsd15 ;;
	*) lab_die 64 "the FreeBSD guest is 14 or 15, not '${1:-}'." ;;
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
	local d py t0 login want out fails=""
	d="$(guest_boot "$guest" lab "$ROUTE" --run "$run" --name "chk-$guest" --owner $$ \
		${cache:+--cache "$cache"})" || exit $?
	py="$(lab_tool python3)"
	want="$([ "$guest" = freebsd14 ] && echo 14.5 || echo 15.1)"
	t0="$(date +%s)"
	"$py" "$LAB_QEMU_DIR/console.py" "$d/serial.sock" --transcript "$d/serial.transcript" \
		login --user root --nudge 3 --timeout 60 || fails="$fails console-login"
	login=$(( $(date +%s) - t0 ))
	out="$("$py" "$LAB_QEMU_DIR/console.py" "$d/serial.sock" --transcript \
		"$d/serial.transcript" run --timeout 30 -- freebsd-version -u)" \
		|| fails="$fails console-run"
	"$py" "$LAB_QEMU_DIR/console.py" "$d/serial.sock" send exit
	case "$out" in "$want"-*) ;; *) fails="$fails version($out)" ;; esac
	out="$(guest_ssh "$d" 'uname -r; doas id -u; pkg info -e fusefs-sshfs && echo sshfs')"
	case "$(printf '%s' "$out" | tr '\n' ' ')" in
	"$want"-*" 0 sshfs") ;;
	*) fails="$fails ssh/doas/sshfs($(printf '%s' "$out" | tr '\n' ' '))" ;;
	esac
	# shellcheck source=/dev/null
	. "$d/guest.env"
	"$LAB_QEMU_DIR/run.sh" stop --run "$run" --name "chk-$guest" --timeout 0
	if [ -n "$fails" ]; then
		echo "$guest: FAILED:$fails (see $d)"
		return 1
	fi
	echo "$guest: console login ok, ssh ok, doas ok (boot $GUEST_BOOT_SECONDS s," \
		"console login $login s)"
}

case "${1:-}" in
boot) shift; g="$(guest_of "${1:-}")" || exit $?; shift; guest_boot "$g" lab "$ROUTE" "$@" ;;
check) shift; g="$(guest_of "${1:-}")" || exit $?; shift; cmd_check "$g" "$@" ;;
lab-route) echo "$ROUTE" ;;
*) usage ;;
esac; exit $?
