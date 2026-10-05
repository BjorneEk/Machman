#!/bin/bash
#
# Lab fixtures: pin, fetch, verify, convert and cache (see scripts/lab/*.lock).
#
#   scripts/lab/fetch.sh path <name>                 print the cached fixture (fetch on a miss)
#   scripts/lab/fetch.sh fetch [--lock FILE] [NAME…] fetch (default: every entry of every lock)
#   scripts/lab/fetch.sh --verify [NAME…]            offline: sizes and hashes against the locks
#   scripts/lab/fetch.sh list                        every entry, its lock, cached or missing
#   scripts/lab/fetch.sh pin <name> <url> [<recipe>] download, prove the recipe, print a lock line
#   scripts/lab/fetch.sh seed <subdir>               clone <subdir> files other worktrees cached
#   scripts/lab/fetch.sh size                        the cache's size
#   scripts/lab/fetch.sh --self-check                offline proof of the recipes and checks
#
# Cache: $MACHMAN_LAB_CACHE, default <this worktree>/scripts/lab/cache (git-ignored), with
# downloads/ fixtures/ built/ bin/ tmp/ locks/. On a miss the files are first cloned (cp -c)
# from another worktree's cache, after checking them against the lock, then downloaded.
# fixtures/<name> is mode 0444: nothing may boot a cached file in place; runs clone it.
# Lock lines: <name> <sha256> <size> <url> [<recipe>]; recipes zboot-unwrap xz gz qcow2-raw.
# Exit: 0 ok, 1 failure/bad, 3 only missing (--verify), 64 usage, 65 bad lock, 69 unavailable.
#
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(cd "$here/../.." && pwd -P)"
CACHE="${MACHMAN_LAB_CACHE:-$repo/scripts/lab/cache}"
LOCKS_DIR="${MACHMAN_LAB_LOCKS_DIR:-$here}"

usage() {
	awk 'NR >= 3 { if ($0 ~ /^set -euo/) exit; sub(/^# ?/, ""); print }' "$0" >&2
	exit 64
}

# --- lock parsing (bash 3.2: parallel arrays) -----------------------------------------------

L_NAME=() L_SHA=() L_SIZE=() L_URL=() L_RECIPE=() L_FILE=()

valid_recipe() {
	case "$1" in "" | zboot-unwrap | xz | gz | qcow2-raw) return 0 ;; *) return 1 ;; esac
}

load_locks() {
	local file line n=0 name sha size url recipe rest lock_files=() i dup
	L_NAME=() L_SHA=() L_SIZE=() L_URL=() L_RECIPE=() L_FILE=()
	if [[ -n "${LOCK_ONLY:-}" ]]; then
		lock_files=("$LOCK_ONLY")
	else
		while IFS= read -r file; do lock_files+=("$file"); done < <(ls "$LOCKS_DIR"/*.lock 2>/dev/null | sort)
	fi
	for file in ${lock_files[@]+"${lock_files[@]}"}; do
		n=0
		while IFS= read -r line || [[ -n "$line" ]]; do
			n=$((n + 1))
			[[ -z "${line// /}" || "$line" == \#* ]] && continue
			read -r name sha size url recipe rest <<<"$line"
			if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ || ! "$sha" =~ ^[0-9a-f]{64}$ ||
				! "$size" =~ ^[0-9]+$ || ! "$url" =~ ^(https|file):// || -n "$rest" ]] ||
				! valid_recipe "${recipe:-}"; then
				echo "fetch.sh: $file:$n: bad lock line: $line" >&2
				exit 65
			fi
			for ((i = 0; i < ${#L_NAME[@]}; i++)); do
				if [[ "${L_NAME[$i]}" == "$name" ]]; then
					dup="${L_FILE[$i]}"
					echo "fetch.sh: $file:$n: $name is already defined in $dup" >&2
					exit 65
				fi
			done
			L_NAME+=("$name") L_SHA+=("$sha") L_SIZE+=("$size") L_URL+=("$url")
			L_RECIPE+=("${recipe:-}") L_FILE+=("$file:$n")
		done <"$file"
	done
}

# find_entry <name>: sets IDX or exits 64.
find_entry() {
	local i
	for ((i = 0; i < ${#L_NAME[@]}; i++)); do
		if [[ "${L_NAME[$i]}" == "$1" ]]; then
			IDX=$i
			return 0
		fi
	done
	echo "fetch.sh: no fixture named $1 in $LOCKS_DIR/*.lock" >&2
	exit 64
}

# --- tools ---------------------------------------------------------------------------------

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
size_of() { stat -f %z "$1"; }

need_python() {
	if [[ "$(command -v python3)" == /usr/bin/python3 ]] && ! xcode-select -p >/dev/null 2>&1; then
		echo "fetch.sh: python3 here is the Command Line Tools shim; install them first" >&2
		exit 69
	fi
}

need_qemu_img() {
	command -v qemu-img >/dev/null 2>&1 || {
		echo "fetch.sh: qemu-img is missing (brew install qemu)" >&2
		exit 69
	}
}

# --- recipes -------------------------------------------------------------------------------

# sparse_write <out>: stdin to <out>; the TRAILING run of all-zero 1 MiB blocks becomes a hole
# (truncate). Zero blocks followed by data are written: on APFS data after a hole materializes
# the file up to it anyway, and a disk image's free space comes last.
sparse_write() {
	need_python
	python3 -c '
import sys
out = sys.argv[1]
pos = 0
pending = 0
with open(out, "wb") as f:
    while True:
        b = sys.stdin.buffer.read(1 << 20)
        if not b:
            break
        if b.count(0) == len(b):
            pending += len(b)
        else:
            while pending:
                n = min(pending, 1 << 20)
                f.write(bytes(n))
                pending -= n
            f.write(b)
        pos += len(b)
    f.truncate(pos)
' "$1"
}

has_armd() { [[ "$(dd if="$1" bs=1 skip=56 count=4 2>/dev/null)" == ARMd ]]; }

# convert <recipe> <in> <out>
convert() {
	case "$1" in
	"") cp -c "$2" "$3" 2>/dev/null || cp "$2" "$3" ;;
	zboot-unwrap)
		need_python
		if has_armd "$2"; then
			cp "$2" "$3"
		else
			python3 -c '
import sys, zlib
d = open(sys.argv[1], "rb").read()
i = d.find(b"\x1f\x8b\x08")
if i < 0:
    sys.exit("fetch.sh: no gzip payload in the EFI zboot image")
open(sys.argv[2], "wb").write(zlib.decompressobj(31).decompress(d[i:]))
' "$2" "$3"
		fi
		has_armd "$3" || { echo "fetch.sh: unwrapping the kernel failed (no ARMd at 56)" >&2; return 1; }
		;;
	xz) xz -dc "$2" | sparse_write "$3" ;;
	gz) gzip -dc "$2" | sparse_write "$3" ;;
	qcow2-raw) need_qemu_img; qemu-img convert -f qcow2 -O raw "$2" "$3" ;;
	*) echo "fetch.sh: unknown recipe $1" >&2; return 1 ;;
	esac
}

# --- cache ---------------------------------------------------------------------------------

cache_dirs() { mkdir -p "$CACHE"/{downloads,fixtures,built,bin,tmp,locks}; }

LOCK_HELD=""
take_fetch_lock() {
	local lock="$CACHE/tmp/.fetch.lock" owner
	cache_dirs
	while ! mkdir "$lock" 2>/dev/null; do
		owner="$(cat "$lock/owner" 2>/dev/null | tr -cd '0-9')"
		if [[ -z "$owner" ]] || ! kill -0 "$owner" 2>/dev/null; then
			rm -rf "$lock"
			continue
		fi
		echo "fetch.sh: another fetch (pid $owner) is running, waiting 5 s" >&2
		sleep 5
	done
	echo "$$" >"$lock/owner"
	LOCK_HELD="$lock"
}
drop_fetch_lock() { [[ -n "$LOCK_HELD" ]] && rm -rf "$LOCK_HELD"; LOCK_HELD=""; }
trap drop_fetch_lock EXIT

# other_caches: the caches of the other worktrees (same relative path), one per line.
other_caches() {
	local wt
	# MACHMAN_LAB_SEED_FROM (self-check): colon-separated caches instead of the worktrees'.
	if [[ -n "${MACHMAN_LAB_SEED_FROM:-}" ]]; then
		tr ':' '\n' <<<"$MACHMAN_LAB_SEED_FROM"
		return 0
	fi
	[[ -n "${MACHMAN_LAB_CACHE:-}" ]] && return 0
	git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' |
		while IFS= read -r wt; do
			[[ "$wt" != "$repo" && -d "$wt/scripts/lab/cache" ]] && echo "$wt/scripts/lab/cache"
		done
	return 0
}

stamp_ok() {  # stamp_ok <idx>: the cached fixture and its stamp match the lock
	local n="${L_NAME[$1]}" stamp
	[[ -f "$CACHE/fixtures/$n" && -f "$CACHE/fixtures/$n.stamp" ]] || return 1
	stamp="$(cut -d' ' -f1 "$CACHE/fixtures/$n.stamp")"
	[[ "$stamp" == "${L_SHA[$1]}" ]]
}

# seed_fixture <idx>: clone a fixture another worktree already built, checking its stamp
# against the lock and its size against the stamp (the hash check is --verify's).
seed_fixture() {
	local n="${L_NAME[$1]}" c stamp osize
	while IFS= read -r c; do
		[[ -n "$c" && -f "$c/fixtures/$n" && -f "$c/fixtures/$n.stamp" ]] || continue
		stamp="$(cat "$c/fixtures/$n.stamp")"
		[[ "${stamp%% *}" == "${L_SHA[$1]}" ]] || continue
		osize="${stamp##* }"
		[[ "$(size_of "$c/fixtures/$n")" == "$osize" ]] || continue
		cp -c "$c/fixtures/$n" "$CACHE/tmp/$n.seed.$$" 2>/dev/null ||
			cp "$c/fixtures/$n" "$CACHE/tmp/$n.seed.$$" || continue
		cp "$c/fixtures/$n.stamp" "$CACHE/fixtures/$n.stamp"
		mv "$CACHE/tmp/$n.seed.$$" "$CACHE/fixtures/$n"
		chmod 0444 "$CACHE/fixtures/$n"
		echo "fetch.sh: $n: cloned from $c" >&2
		return 0
	done < <(other_caches)
	return 1
}

seed_download() {  # seed_download <idx>: a pinned download another worktree holds
	local n="${L_NAME[$1]}" c f="" d
	d="$CACHE/downloads/$n.download"
	while IFS= read -r c; do
		f="$c/downloads/$n.download"
		[[ -f "$f" && "$(size_of "$f")" == "${L_SIZE[$1]}" && "$(sha_of "$f")" == "${L_SHA[$1]}" ]] ||
			continue
		cp -c "$f" "$CACHE/tmp/$n.seed.$$" 2>/dev/null || cp "$f" "$CACHE/tmp/$n.seed.$$" || continue
		mv "$CACHE/tmp/$n.seed.$$" "$d"
		chmod 0444 "$d"
		return 0
	done < <(other_caches)
	return 1
}

download_ok() {  # download_ok <idx>
	local d="$CACHE/downloads/${L_NAME[$1]}.download"
	[[ -f "$d" && "$(size_of "$d")" == "${L_SIZE[$1]}" && "$(sha_of "$d")" == "${L_SHA[$1]}" ]]
}

# ensure <idx>: leave a verified fixture in the cache.
ensure() {
	local i="$1" n="${L_NAME[$1]}" part got gotsize d out ostamp
	cache_dirs
	stamp_ok "$i" && return 0
	take_fetch_lock
	stamp_ok "$i" && { drop_fetch_lock; return 0; }
	if seed_fixture "$i"; then
		drop_fetch_lock
		return 0
	fi
	d="$CACHE/downloads/$n.download"
	if ! download_ok "$i"; then
		rm -f "$d"
		if ! seed_download "$i"; then
			part="$CACHE/tmp/$n.part.$$"
			curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$part" "${L_URL[$i]}"
			got="$(sha_of "$part")"
			gotsize="$(size_of "$part")"
			if [[ "$got" != "${L_SHA[$i]}" || "$gotsize" != "${L_SIZE[$i]}" ]]; then
				rm -f "$part"
				echo "fetch.sh: $n: sha256 $got ($gotsize bytes), pinned ${L_SHA[$i]}" \
					"(${L_SIZE[$i]} bytes) — upstream changed the file: re-pin with" \
					"'scripts/lab/fetch.sh pin'" >&2
				exit 1
			fi
			mv "$part" "$d"
			chmod 0444 "$d"
		fi
	fi
	out="$CACHE/tmp/$n.out.$$"
	if ! convert "${L_RECIPE[$i]}" "$d" "$out"; then
		rm -f "$out"
		exit 1
	fi
	echo "${L_SHA[$i]} ${L_RECIPE[$i]:--} $(sha_of "$out") $(size_of "$out")" >"$CACHE/tmp/$n.stamp.$$"
	mv "$CACHE/tmp/$n.stamp.$$" "$CACHE/fixtures/$n.stamp"
	mv "$out" "$CACHE/fixtures/$n"
	chmod 0444 "$CACHE/fixtures/$n"
	drop_fetch_lock
}

# --- commands ------------------------------------------------------------------------------

cmd_path() {
	[[ $# == 1 ]] || usage
	load_locks
	find_entry "$1"
	ensure "$IDX" >&2
	echo "$CACHE/fixtures/$1"
}

cmd_fetch() {
	local names=() i
	LOCK_ONLY=""
	while (($#)); do
		case "$1" in
		--lock) LOCK_ONLY="${2:?--lock needs a file}"; shift ;;
		*) names+=("$1") ;;
		esac
		shift
	done
	load_locks
	if ((${#names[@]})); then
		for n in "${names[@]}"; do
			find_entry "$n"
			ensure "$IDX"
			echo "ok $n"
		done
	else
		for ((i = 0; i < ${#L_NAME[@]}; i++)); do
			ensure "$i"
			echo "ok ${L_NAME[$i]}"
		done
	fi
}

cmd_verify() {
	local names=() i n bad=0 missing=0 d stamp f recipe osha osize
	load_locks
	if (($#)); then
		for n in "$@"; do
			find_entry "$n"
			names+=("$IDX")
		done
	else
		for ((i = 0; i < ${#L_NAME[@]}; i++)); do names+=("$i"); done
	fi
	for i in ${names[@]+"${names[@]}"}; do
		n="${L_NAME[$i]}"
		f="$CACHE/fixtures/$n"
		if [[ ! -f "$f" || ! -f "$f.stamp" ]]; then
			echo "MISSING $n (not fetched: scripts/lab/fetch.sh fetch $n)"
			missing=1
			continue
		fi
		read -r stamp recipe osha osize <"$f.stamp"
		d="$CACHE/downloads/$n.download"
		if [[ "$stamp" != "${L_SHA[$i]}" ]]; then
			echo "BAD $n: its stamp is for another pin (re-fetch)"
			bad=1
		elif [[ ! -f "$d" ]]; then
			echo "ok $n (download not kept)"
			[[ "$(size_of "$f")" == "$osize" && "$(sha_of "$f")" == "$osha" ]] || {
				echo "BAD $n: the fixture differs from its stamp"
				bad=1
			}
		elif [[ "$(size_of "$d")" != "${L_SIZE[$i]}" || "$(sha_of "$d")" != "${L_SHA[$i]}" ]]; then
			echo "BAD $n: the download differs from the pin"
			bad=1
		elif [[ "$(size_of "$f")" != "$osize" || "$(sha_of "$f")" != "$osha" ]]; then
			echo "BAD $n: the fixture differs from its stamp"
			bad=1
		else
			echo "ok $n"
		fi
	done
	((bad)) && return 1
	((missing)) && return 3
	return 0
}

cmd_list() {
	load_locks
	local i state
	for ((i = 0; i < ${#L_NAME[@]}; i++)); do
		state=missing
		stamp_ok "$i" && state=cached
		echo "${L_NAME[$i]} ${L_FILE[$i]%:*} ${L_RECIPE[$i]:--} $state"
	done
}

cmd_pin() {
	[[ $# -ge 2 && $# -le 3 ]] || usage
	local name="$1" url="$2" recipe="${3:-}" tmp
	cache_dirs
	tmp="$CACHE/tmp/pin.$$"
	mkdir -p "$tmp"
	curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$tmp/in" "$url"
	convert "$recipe" "$tmp/in" "$tmp/out" || { rm -rf "$tmp"; exit 1; }
	echo "$name $(sha_of "$tmp/in") $(size_of "$tmp/in") $url $recipe" | sed 's/ $//'
	rm -rf "$tmp"
}

cmd_seed() {
	[[ $# == 1 && "$1" =~ ^[a-z]+$ ]] || usage
	local c f base
	mkdir -p "$CACHE/$1"
	while IFS= read -r c; do
		for f in "$c/$1"/*; do
			[[ -f "$f" ]] || continue
			base="${f##*/}"
			[[ -e "$CACHE/$1/$base" ]] && continue
			cp -c "$f" "$CACHE/$1/$base.seed.$$" 2>/dev/null || cp "$f" "$CACHE/$1/$base.seed.$$"
			mv "$CACHE/$1/$base.seed.$$" "$CACHE/$1/$base"
			echo "fetch.sh: $1/$base: cloned from $c" >&2
		done
	done < <(other_caches)
	return 0
}

cmd_size() { mkdir -p "$CACHE"; du -sh "$CACHE" | cut -f1; }

# --- self-check ----------------------------------------------------------------------------

selfcheck() {
	local failures=0 sc locks out got
	cache_dirs
	sc="$CACHE/tmp/selfcheck.$$"
	mkdir -p "$sc/locks" "$sc/src"
	trap 'rm -rf "$sc"; drop_fetch_lock' EXIT
	ok() { echo "ok   $1"; }
	fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
	# sc_run <args...>: this script against a private cache and lock dir.
	sc_run() {
		MACHMAN_LAB_CACHE="$sc/cache" MACHMAN_LAB_LOCKS_DIR="$sc/locks" "$here/fetch.sh" "$@"
	}
	sc_lock() {  # sc_lock <name> <file> [recipe]: write a lock line for a local file
		echo "$1 $(sha_of "$2") $(size_of "$2") file://$2 ${3:-}" >>"$sc/locks/t.lock"
	}
	local PY=python3
	need_python

	# 1 zboot-unwrap of a fake zboot
	"$PY" -c '
import gzip, sys
img = bytearray(4096)
img[56:60] = b"ARMd"
open(sys.argv[1], "wb").write(bytes(img))
open(sys.argv[2], "wb").write(b"x" * 100 + gzip.compress(bytes(img)))
' "$sc/src/image" "$sc/src/zboot"
	sc_lock zb "$sc/src/zboot" zboot-unwrap
	if sc_run fetch zb >/dev/null 2>&1 && cmp -s "$sc/src/image" "$sc/cache/fixtures/zb"; then
		ok "recipe zboot-unwrap: a fake zboot image unwraps to its Image"
	else
		fail "recipe zboot-unwrap: a fake zboot image unwraps to its Image" "output differs"
	fi

	# 2 raw ARMd passes through
	sc_lock raw "$sc/src/image" zboot-unwrap
	if sc_run fetch raw >/dev/null 2>&1 && cmp -s "$sc/src/image" "$sc/cache/fixtures/raw"; then
		ok "recipe zboot-unwrap: a raw arm64 kernel passes through"
	else
		fail "recipe zboot-unwrap: a raw arm64 kernel passes through" "output differs"
	fi

	# 3/4 xz and gz make sparse outputs
	"$PY" -c '
import sys
open(sys.argv[1], "wb").write(b"x" + b"\0" * (64 << 20))
' "$sc/src/big"
	xz -c "$sc/src/big" >"$sc/src/big.xz"
	gzip -c "$sc/src/big" >"$sc/src/big.gz"
	for r in xz gz; do
		sc_lock "big-$r" "$sc/src/big.$r" "$r"
		if sc_run fetch "big-$r" >/dev/null 2>&1 && cmp -s "$sc/src/big" "$sc/cache/fixtures/big-$r" &&
			(($(du -k "$sc/cache/fixtures/big-$r" | cut -f1) < 8192)); then
			ok "recipe $r: one byte and 64 MiB of zeros convert to an equal, sparse file"
		else
			fail "recipe $r: one byte and 64 MiB of zeros convert to an equal, sparse file" \
				"not equal or not sparse"
		fi
	done

	# 5 qcow2-raw
	if command -v qemu-img >/dev/null 2>&1; then
		qemu-img create -q -f qcow2 "$sc/src/disk.qcow2" 8M
		sc_lock disk "$sc/src/disk.qcow2" qcow2-raw
		if sc_run fetch disk >/dev/null 2>&1 &&
			[[ "$(size_of "$sc/cache/fixtures/disk")" == 8388608 ]]; then
			ok "recipe qcow2-raw: an 8M qcow2 converts to an 8388608-byte raw"
		else
			fail "recipe qcow2-raw: an 8M qcow2 converts to an 8388608-byte raw" "wrong size"
		fi
	else
		echo "skip recipe qcow2-raw (no qemu-img)"
	fi

	# 6 a wrong sha is refused
	echo "bad $(printf '0%.0s' $(seq 1 64)) $(size_of "$sc/src/image") file://$sc/src/image" \
		>>"$sc/locks/t.lock"
	if out="$(sc_run fetch bad 2>&1)"; then
		fail "pin: a wrong sha256 is refused and leaves no fixture" "fetch succeeded"
	elif [[ ! -e "$sc/cache/fixtures/bad" && "$out" == *"upstream changed the file"* ]]; then
		ok "pin: a wrong sha256 is refused and leaves no fixture"
	else
		fail "pin: a wrong sha256 is refused and leaves no fixture" "$out"
	fi

	# 7 duplicate names across two locks exit 65
	cp "$sc/locks/t.lock" "$sc/locks/u.lock"
	got=0
	sc_run list >/dev/null 2>&1 || got=$?
	if [[ $got == 65 ]]; then
		ok "locks: a duplicate name across two locks exits 65"
	else
		fail "locks: a duplicate name across two locks exits 65" "exit $got"
	fi
	rm -f "$sc/locks/u.lock"
	sed -i '' '/^bad /d' "$sc/locks/t.lock"

	# 8 --verify: ok after a fetch, BAD after a flipped byte of the download
	if sc_run --verify zb >/dev/null 2>&1; then
		chmod u+w "$sc/cache/downloads/zb.download"
		printf 'Z' | dd of="$sc/cache/downloads/zb.download" bs=1 seek=0 conv=notrunc 2>/dev/null
		out="$(sc_run --verify zb 2>&1 || true)"
		if [[ "$out" != "BAD zb"* ]]; then
			fail "verify: ok after a fetch, BAD after a flipped byte of the download" "not BAD"
		else
			ok "verify: ok after a fetch, BAD after a flipped byte of the download"
		fi
	else
		fail "verify: ok after a fetch, BAD after a flipped byte of the download" "not ok at first"
	fi

	# 9 seeding from another worktree's cache, checked against the lock, no download
	{
		out="$(MACHMAN_LAB_SEED_FROM="$sc/cache" MACHMAN_LAB_CACHE="$sc/cache2" \
			MACHMAN_LAB_LOCKS_DIR="$sc/locks" "$here/fetch.sh" fetch big-xz 2>&1)" || true
		if [[ "$out" == *"cloned from $sc/cache"* ]] &&
			cmp -s "$sc/src/big" "$sc/cache2/fixtures/big-xz"; then
			ok "seed: a fixture another worktree built is cloned, not downloaded"
		else
			fail "seed: a fixture another worktree built is cloned, not downloaded" "$out"
		fi
	}
	exit "$failures"
}

# --- main ----------------------------------------------------------------------------------

[[ $# -ge 1 ]] || usage
cmd="$1"
shift
case "$cmd" in
path) cmd_path "$@" ;;
fetch) cmd_fetch "$@" ;;
--verify | verify) cmd_verify "$@" ;;
list) cmd_list ;;
pin) cmd_pin "$@" ;;
seed) cmd_seed "$@" ;;
size) cmd_size ;;
--self-check) selfcheck ;;
*) usage ;;
esac
