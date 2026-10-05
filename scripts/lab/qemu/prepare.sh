#!/bin/bash
# Prepared lab images: each guest's packages installed ONCE per (pinned base image, prepare
# script), under QEMU with open networking, and cached — so tests never touch the network.
#
#   prepare.sh path <guest> [--base <raw>] [--cache <dir>] [--run <root>] [--no-build]
#                                    the image (built on a miss; --no-build: exit 69 instead)
#   prepare.sh build <guest> [--base <raw>] [--cache <dir>] [--run <root>] [--force]
#   prepare.sh list [--cache <dir>]
#
# Guests: freebsd14 freebsd15 (guests/freebsd), debian debian-sysv (guests/debian). Each guest
# dir's guest.conf names the base (a lock name) and holds provision(); its prepare script runs
# in the guest. The key is the first 12 hex of sha256 over the base's sha256, the prepare
# script(s), guest.conf and run.sh's RUNNER_VERSION line; a derived guest (debian-sysv) keys on
# its parent's prepared image. Cache (<cache> = --cache, MACHMAN_LAB_CACHE, else the worktree's
# scripts/lab/cache): <cache>/prepared/<guest>-<key>.{raw (0444), id_ed25519 (+.pub, 0600),
# manifest, stamp}. A miss first seeds from another worktree's cache (APFS clone, stamp
# verified), then builds.
#
# The base: --base, else <cache>/fixtures/<lock name> with fetch.sh's stamp (step 11 resolves
# it through scripts/lab/fetch.sh path). Builds boot QEMU: the caller holds the lab slot.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"
# shellcheck source=../sshd/ssh-opts.sh
. "$LAB_DIR/sshd/ssh-opts.sh"

GUESTS="freebsd14 freebsd15 debian debian-sysv"

usage() {
	sed -n '5,8p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 64
}

prep_log() { echo "prepare.sh: ${GUEST:-}: $*" >&2; }

guest_dir() {
	case "$1" in
	freebsd14|freebsd15) printf '%s\n' "$LAB_DIR/guests/freebsd" ;;
	debian|debian-sysv) printf '%s\n' "$LAB_DIR/guests/debian" ;;
	*) return 1 ;;
	esac
}

load_guest() { # <guest>: sets GUEST, GDIR and what guest.conf defines
	GUEST="$1"
	GDIR="$(guest_dir "$1")" || lab_die 64 "no lab guest '$1' (one of: $GUESTS)."
	GUEST_FROM=""
	# shellcheck source=../guests/freebsd/guest.conf
	. "$GDIR/guest.conf"
}

# sha_memo <file>: its sha256, memoized by (device, inode, size, mtime) in the cache.
sha_memo() {
	local id memo
	id="$(stat -f '%d-%i-%z-%m' "$1")" || return 1
	memo="$CACHE/prepared/.sha/$id"
	if [ ! -f "$memo" ]; then
		mkdir -p "$CACHE/prepared/.sha"
		shasum -a 256 "$1" | cut -d' ' -f1 > "$memo.$$" && mv "$memo.$$" "$memo"
	fi
	cat "$memo"
}

# resolve_base: sets BASE (a file) and BASE_ID for the loaded guest.
resolve_base() {
	if [ -n "$GUEST_FROM" ]; then
		BASE="$("$HERE/prepare.sh" path "$GUEST_FROM" --cache "$CACHE" ${RUN:+--run "$RUN"})" \
			|| lab_die 1 "$GUEST: its parent $GUEST_FROM could not be prepared."
		BASE_ID="prepared:$(basename "$BASE" .raw)"
		return 0
	fi
	if [ -n "$BASE_ARG" ]; then
		[ -f "$BASE_ARG" ] || lab_die 64 "no base image at '$BASE_ARG'."
		BASE="$BASE_ARG"
		BASE_ID="$(sha_memo "$BASE")"
		return 0
	fi
	local f="$CACHE/fixtures/$GUEST_BASE"
	if [ -f "$f" ] && [ -f "$f.stamp" ]; then
		BASE="$f"
		BASE_ID="$(cut -d' ' -f3 "$f.stamp")"
		return 0
	fi
	lab_die 69 "no base image $GUEST_BASE for $GUEST: pass --base <raw>" \
		"(step 11 resolves it with scripts/lab/fetch.sh path $GUEST_BASE)."
}

prep_key() {
	{
		echo "$BASE_ID"
		cat "$GUEST_PREPARE"
		cat "$GDIR/guest.conf"
		grep '^RUNNER_VERSION=' "$HERE/run.sh"
	} | shasum -a 256 | cut -c1-12
}

# --- helpers for guest.conf's provision() --------------------------------------------------

prep_boot() { # <build dir> <run> <name> [run.sh start args…]
	local b="$1" run="$2" name="$3"
	shift 3
	MACHMAN_LAB_PREPARE=1 "$HERE/run.sh" start --run "$run" --name "$name" --disk "$b/disk.raw" \
		--net open --ssh-forward --cpus 2 --mem 2048 --owner $$ "$@" >/dev/null
}

prep_port() { cat "$1/qemu/$2/ssh.port"; }

prep_ssh() { # <run> <name> <user> <key> <command…>
	local run="$1" name="$2" user="$3" key="$4"
	shift 4
	LAB_KNOWN_HOSTS="$run/qemu/$name/known_hosts" \
		lab_ssh "$run" "$key" "$user@127.0.0.1" "$(prep_port "$run" "$name")" "$@"
}

prep_scp() { # <run> <name> <user> <key> <local file> <remote path>
	LAB_KNOWN_HOSTS="$1/qemu/$2/known_hosts" \
		lab_scp "$1" "$4" "$(prep_port "$1" "$2")" "$5" "$3@127.0.0.1:$6"
}

prep_wait_ssh() { # <run> <name> <user> <key> <timeout s>
	local t=0
	until prep_ssh "$1" "$2" "$3" "$4" true </dev/null >/dev/null 2>&1; do
		[ "$t" -ge "$5" ] && { prep_log "no ssh as $3 within $5 s"; return 1; }
		sleep 5
		t=$((t + 5))
	done
}

prep_wait_exit() { # <run> <name> <timeout s>: wait for the guest to power off
	local pid t=0
	pid="$(lab_pid_of "$1/pids/qemu-$2.pid")" || return 0
	while lab_pid_is "$pid" qemu-system-aarch64; do
		if [ "$t" -ge "$3" ]; then
			prep_log "no power-off within $3 s: stopping QEMU"
			"$HERE/run.sh" stop --run "$1" --name "$2" --timeout 0
			return 1
		fi
		sleep 2
		t=$((t + 2))
	done
	"$HERE/run.sh" stop --run "$1" --name "$2" --timeout 0
}

# prep_console <run> <name> <console: serial|hvc<i>> <user> <timeout> <command>
prep_console() {
	local py sock
	py="$(lab_tool python3)"
	sock="$1/qemu/$2/$3.sock"
	"$py" "$HERE/console.py" "$sock" --transcript "$1/qemu/$2/$3.transcript" login \
		--user "$4" --nudge 5 --timeout 120 || return 1
	"$py" "$HERE/console.py" "$sock" --transcript "$1/qemu/$2/$3.transcript" run \
		--timeout "$5" -- "$6"
}

# --- the cache ---------------------------------------------------------------------------

cached() { [ -f "$CACHE/prepared/$GUEST-$KEY.raw" ]; }

# The other caches a miss may seed from: every worktree's scripts/lab/cache (C-1), or the
# colon-separated MACHMAN_LAB_SEED_CACHES (self-checks).
seed_caches() {
	if [ -n "${MACHMAN_LAB_SEED_CACHES:-}" ]; then
		printf '%s\n' "$MACHMAN_LAB_SEED_CACHES" | tr ':' '\n'
		return 0
	fi
	"$(lab_tool git)" -C "$LAB_REPO" worktree list --porcelain 2>/dev/null \
		| sed -n 's|^worktree \(.*\)$|\1/scripts/lab/cache|p'
}

# seed_from_worktrees: an APFS clone of the same prepared image from another cache.
seed_from_worktrees() {
	local wt src dst="$CACHE/prepared" f sum size w
	seed_caches | while IFS= read -r wt; do
		src="$wt/prepared"
		[ -d "$src" ] || continue
		[ -f "$src/$GUEST-$KEY.raw" ] && [ -f "$src/$GUEST-$KEY.stamp" ] || continue
		[ "$(cd "$src" && pwd -P)" = "$(cd "$dst" && pwd -P)" ] && continue
		w="$dst/.work-$$"
		rm -rf "$w"
		mkdir -p "$w"
		for f in raw id_ed25519 id_ed25519.pub manifest stamp; do
			cp -c "$src/$GUEST-$KEY.$f" "$w/$f" 2>/dev/null || { rm -rf "$w"; continue 2; }
		done
		read -r sum size < "$w/stamp"
		if [ "$(shasum -a 256 "$w/raw" | cut -d' ' -f1)" = "$sum" ] \
			&& [ "$(stat -f %z "$w/raw")" = "$size" ]; then
			install_work "$w"
			prep_log "seeded from $wt"
			exit 0
		fi
		rm -rf "$w"
	done
}

# install_work <dir>: move a finished build into place, the image last (its presence = a hit).
install_work() {
	local w="$1" d="$CACHE/prepared" f
	chmod 600 "$w/id_ed25519"
	chmod 444 "$w/raw"
	for f in id_ed25519 id_ed25519.pub manifest stamp; do
		mv -f "$w/$f" "$d/$GUEST-$KEY.$f"
	done
	mv -f "$w/raw" "$d/$GUEST-$KEY.raw"
	rm -rf "$w"
}

# Remove build leftovers whose builder is gone.
sweep_work() {
	local w p
	for w in "$CACHE"/prepared/.work-*; do
		[ -d "$w" ] || continue
		p="${w##*.work-}"
		kill -0 "$p" 2>/dev/null || rm -rf "$w"
	done
}

build() {
	local own_run="" b w
	if [ -z "$RUN" ]; then
		RUN="$(lab_new_root)"
		own_run="$RUN"
	fi
	lab_check_run_root "$RUN"
	lab_refuse_main_checkout
	b="$RUN/prepare-$GUEST"
	rm -rf "$b"
	mkdir -p "$b"
	prep_log "building $GUEST-$KEY from $(basename "$BASE") (run $RUN)"
	local t0
	t0="$(date +%s)"
	cp -c "$BASE" "$b/disk.raw" || lab_die 1 "cannot clone $BASE (cp -c)."
	chmod 644 "$b/disk.raw"
	dd if=/dev/zero of="$b/disk.raw" bs=1 count=0 seek=$((GUEST_DISK_GIB * 1073741824)) \
		2>/dev/null
	ssh-keygen -q -t ed25519 -N '' -C "lab-$GUEST-$KEY" -f "$b/id_ed25519" </dev/null \
		|| lab_die 1 "ssh-keygen failed."
	if ! PREP_KEY="$KEY" provision "$b" "$RUN"; then
		"$HERE/run.sh" stop --run "$RUN" --name "prep-$GUEST" --timeout 0
		prep_log "provisioning failed; logs in $RUN/qemu/prep-$GUEST (kept)"
		exit 1
	fi
	echo "prepare-seconds $(( $(date +%s) - t0 ))" >> "$b/manifest"
	echo "$(shasum -a 256 "$b/disk.raw" | cut -d' ' -f1) $(stat -f %z "$b/disk.raw")" \
		> "$b/stamp"
	w="$CACHE/prepared/.work-$$"
	rm -rf "$w"
	mkdir -p "$w"
	mv "$b/disk.raw" "$w/raw"
	mv "$b/id_ed25519" "$w/id_ed25519"
	mv "$b/id_ed25519.pub" "$w/id_ed25519.pub"
	mv "$b/manifest" "$w/manifest"
	mv "$b/stamp" "$w/stamp"
	install_work "$w"
	sweep_work
	[ -n "$own_run" ] && { "$HERE/run.sh" sweep "$own_run"; rm -rf "$own_run"; }
	return 0
}

main() {
	local cmd="${1:-}" force=0 nobuild=0
	[ $# -gt 0 ] && shift
	case "$cmd" in
	path|build) [ $# -gt 0 ] || usage; load_guest "$1"; shift ;;
	list) ;;
	*) usage ;;
	esac
	BASE_ARG="" RUN=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--base) BASE_ARG="${2:-}"; shift 2 ;;
		--cache) MACHMAN_LAB_CACHE="${2:-}"; export MACHMAN_LAB_CACHE; shift 2 ;;
		--run) RUN="${2:-}"; shift 2 ;;
		--force) force=1; shift ;;
		--no-build) nobuild=1; shift ;;
		*) usage ;;
		esac
	done
	CACHE="$(lab_cache_dir)"
	mkdir -p "$CACHE/prepared"
	if [ "$cmd" = list ]; then
		local f
		for f in "$CACHE"/prepared/*.raw; do
			[ -f "$f" ] || continue
			printf '%s %s %s\n' "$(basename "$f" .raw)" "$(du -h "$f" | cut -f1)" \
				"$(grep -m1 -E '^(freebsd-version-u|debian|pid1) ' "${f%.raw}.manifest" \
				2>/dev/null)"
		done
		return 0
	fi
	resolve_base
	KEY="$(prep_key)"
	if [ "$cmd" = path ] || [ "$force" = 0 ]; then
		cached || seed_from_worktrees
		if cached; then
			printf '%s\n' "$CACHE/prepared/$GUEST-$KEY.raw"
			return 0
		fi
	fi
	[ "$nobuild" = 0 ] \
		|| lab_die 69 "no prepared $GUEST image (scripts/lab/qemu/prepare.sh build $GUEST)."
	build
	printf '%s\n' "$CACHE/prepared/$GUEST-$KEY.raw"
}

main "$@"; exit $?
