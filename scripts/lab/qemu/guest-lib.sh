# Sourced (bash 3.2) by guests/<os>/guest.sh: boot a prepared lab guest under qemu/run.sh and
# reach it. Every per-run boot is a clone of the prepared image (never the cache), restricted
# networking (no host, no internet), ssh only through the 127.0.0.1 forward with the image's
# baked key, and the guest's default route moved to the lab gateway 10.0.2.100 — whose port 22
# is the lab sshd (--lab-gateway <port>) or nothing — so "the Mac" a guest script finds as its
# gateway is never this Mac's real sshd.
#
# A booted guest's dir <run>/qemu/<name>/ gets guest.env (GUEST, GUEST_NAME, GUEST_USER,
# GUEST_PORT, GUEST_KEY, GUEST_IMAGE) and id_ed25519 (the baked key, 0600).

# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=../sshd/ssh-opts.sh
. "$LAB_DIR/sshd/ssh-opts.sh"

GUEST_LAB_GATEWAY=10.0.2.100

# guest_ssh <guest dir> <command…>: ssh as the guest's user with its baked key.
guest_ssh() {
	local d="$1"
	shift
	(
		# shellcheck source=/dev/null
		. "$d/guest.env"
		LAB_KNOWN_HOSTS="$d/known_hosts" lab_ssh "${d%/qemu/*}" "$GUEST_KEY" \
			"$GUEST_USER@127.0.0.1" "$GUEST_PORT" "$@"
	)
}

# guest_wait_ssh <guest dir> <timeout s>
guest_wait_ssh() {
	local end=$((SECONDS + $2))
	until guest_ssh "$1" true </dev/null >/dev/null 2>&1; do
		[ "$SECONDS" -ge "$end" ] && return 1
		sleep 2
	done
}

# guest_boot <guest> <user> <route command> <args…>: --run <root> [--name N]
#   [--lab-gateway <port>|none] [--consoles N] [--owner PID] [--cache D] [--image <raw>]
#   [--mem MB]. Prints the guest dir; exits 69 when the prepared image is missing.
guest_boot() {
	local guest="$1" user="$2" route="$3"
	shift 3
	local run="" name="$guest" gateway=none consoles=0 owner="" image="" mem=1024
	while [ $# -gt 0 ]; do
		case "$1" in
		--run) run="${2:-}"; shift 2 ;;
		--name) name="${2:-}"; shift 2 ;;
		--lab-gateway) gateway="${2:-}"; shift 2 ;;
		--consoles) consoles="${2:-}"; shift 2 ;;
		--owner) owner="${2:-}"; shift 2 ;;
		--cache) MACHMAN_LAB_CACHE="${2:-}"; export MACHMAN_LAB_CACHE; shift 2 ;;
		--image) image="${2:-}"; shift 2 ;;
		--mem) mem="${2:-}"; shift 2 ;;
		*) lab_die 64 "unknown boot option '$1'." ;;
		esac
	done
	lab_check_run_root "$run"
	if [ -z "$image" ]; then
		image="$("$LAB_QEMU_DIR/prepare.sh" path "$guest" --no-build)" || exit $?
	fi
	[ -f "$image" ] && [ -f "${image%.raw}.id_ed25519" ] \
		|| lab_die 69 "no prepared $guest image at '$image'."
	local d="$run/qemu/$name" t0
	mkdir -p "$d"
	rm -f "$d/disk.raw" "$d/known_hosts"
	cp -c "$image" "$d/disk.raw" || lab_die 1 "cannot clone $image (cp -c)."
	chmod 644 "$d/disk.raw"
	cp "${image%.raw}.id_ed25519" "$d/id_ed25519"
	chmod 600 "$d/id_ed25519"
	t0="$(date +%s)"
	"$LAB_QEMU_DIR/run.sh" start --run "$run" --name "$name" --disk "$d/disk.raw" \
		--net restricted --ssh-forward --lab-gateway "$gateway" --consoles "$consoles" \
		--cpus 2 --mem "$mem" ${owner:+--owner "$owner"} >/dev/null || exit $?
	cat > "$d/guest.env" <<EOF
GUEST='$guest'
GUEST_NAME='$name'
GUEST_USER='$user'
GUEST_PORT='$(cat "$d/ssh.port")'
GUEST_KEY='$d/id_ed25519'
GUEST_IMAGE='$image'
EOF
	if ! guest_wait_ssh "$d" 180; then
		"$LAB_QEMU_DIR/run.sh" stop --run "$run" --name "$name" --timeout 0
		lab_die 1 "$guest: no ssh within 180 s (see $d/serial.log)."
	fi
	echo "GUEST_BOOT_SECONDS='$(( $(date +%s) - t0 ))'" >> "$d/guest.env"
	guest_ssh "$d" "$route" >/dev/null 2>&1 \
		|| lab_die 1 "$guest: could not move the default route to $GUEST_LAB_GATEWAY."
	printf '%s\n' "$d"
}
