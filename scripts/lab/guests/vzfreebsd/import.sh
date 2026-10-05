#!/bin/bash
# The vzfreebsd image (FreeBSD patched to run under Apple VZ, built in its own read-only repo)
# imported into the lab cache as an APFS clone, with where it came from recorded.
#
#   import.sh path       the cached clone; re-imports when the source changed. Exit 3 with
#                        "vzfreebsd image not built (make image in <SRC>)" when there is no
#                        <SRC>/out/vzfreebsd.raw, or "vzfreebsd is being built (<SRC>/work/.lock
#                        present)" while its build runs
#   import.sh status     the record of the current import
#   import.sh --self-check
#
# SRC is MACHMAN_LAB_VZFREEBSD, else ~/dev/2026/vzfreebsd (the account's home, not $HOME). The
# source is never written: a clone (cp -c, no copy fallback), git rev-parse, and git status
# without optional locks (no index refresh); never make. Cache: <cache>/vzfreebsd/
# vzfreebsd-<sha12>.raw (0444) + .json (source, size, mtime, git head and dirtiness, the
# freebsd.lock pin, sha256, import time).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../qemu/common.sh
. "$HERE/../../qemu/common.sh"

usage() {
	sed -n '4,11p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 64
}

src_dir() {
	if [ -n "${MACHMAN_LAB_VZFREEBSD:-}" ]; then
		printf '%s\n' "$MACHMAN_LAB_VZFREEBSD"
	else
		printf '%s/dev/2026/vzfreebsd\n' "$(eval echo "~$(id -un)")"
	fi
}

dest_dir() { printf '%s/vzfreebsd\n' "$(lab_cache_dir)"; }

# The stat identity a record was made from: size and mtime of the source image.
src_id() { stat -f '%z %m' "$1"; }

# current_record: the record (json) whose clone exists, newest first.
current_record() {
	local j
	for j in $(ls -t "$(dest_dir)"/vzfreebsd-*.json 2>/dev/null); do
		[ -f "${j%.json}.raw" ] && { printf '%s\n' "$j"; return 0; }
	done
	return 1
}

json_field() { # <file> <key>
	"$(lab_tool python3)" -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
		"$1" "$2"
}

check_source() { # exit 3 when there is nothing to import
	local src="$1"
	if [ -e "$src/work/.lock" ]; then
		echo "vzfreebsd is being built ($src/work/.lock present)"
		exit 3
	fi
	if [ ! -f "$src/out/vzfreebsd.raw" ]; then
		echo "vzfreebsd image not built (make image in $src)"
		exit 3
	fi
}

do_import() {
	local src="$1" dest img part sum j git head dirty
	dest="$(dest_dir)"
	img="$src/out/vzfreebsd.raw"
	mkdir -p "$dest"
	part="$dest/.part-$$"
	rm -f "$part"
	cp -c "$img" "$part" 2>/dev/null \
		|| lab_die 1 "cannot clone $img into $dest (cp -c): the lab cache must be on its volume."
	sum="$(shasum -a 256 "$part" | cut -d' ' -f1)"
	git="$(lab_tool git)"
	head="$("$git" -C "$src" rev-parse HEAD 2>/dev/null || echo unknown)"
	dirty="$(GIT_OPTIONAL_LOCKS=0 "$git" --no-optional-locks -C "$src" status --porcelain \
		--untracked-files=no 2>/dev/null | head -n 20)"
	j="$dest/vzfreebsd-${sum:0:12}.json"
	"$(lab_tool python3)" - "$j" "$img" "$(src_id "$img")" "$head" "$dirty" "$src/freebsd.lock" \
		"$sum" <<'EOF'
import json, sys, time
out, img, ident, head, dirty, lock, sha = sys.argv[1:8]
size, mtime = ident.split()
pin = {}
try:
	for line in open(lock):
		line = line.strip()
		if "=" in line and not line.startswith("#"):
			k, v = line.split("=", 1)
			pin[k.strip()] = v.strip()
except OSError:
	pass
rec = {
	"source": img, "source_size": int(size), "source_mtime": int(mtime),
	"git_head": head, "git_dirty": [l for l in dirty.splitlines() if l],
	"freebsd_url": pin.get("FREEBSD_URL", ""), "freebsd_branch": pin.get("FREEBSD_BRANCH", ""),
	"freebsd_commit": pin.get("FREEBSD_COMMIT", ""), "sha256": sha,
	"imported_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
with open(out, "w") as f:
	json.dump(rec, f, indent=1)
	f.write("\n")
EOF
	chmod 444 "$part"
	mv -f "$part" "${j%.json}.raw"
	# Older imports go: one current clone.
	local old
	for old in "$dest"/vzfreebsd-*.json; do
		[ "$old" = "$j" ] && continue
		rm -f "$old" "${old%.json}.raw"
	done
	printf '%s\n' "${j%.json}.raw"
}

cmd_path() {
	local src j img
	src="$(src_dir)"
	check_source "$src"
	img="$src/out/vzfreebsd.raw"
	if j="$(current_record)" \
		&& [ "$(json_field "$j" source_size) $(json_field "$j" source_mtime)" = "$(src_id "$img")" ]
	then
		printf '%s\n' "${j%.json}.raw"
		return 0
	fi
	do_import "$src"
}

cmd_status() {
	local j
	if j="$(current_record)"; then
		cat "$j"
	else
		echo "no vzfreebsd import in $(dest_dir)"
		return 1
	fi
}

self_check() {
	local root fails=0 src out rc p1 p2 p3 before after git
	root="$(lab_new_root)"
	SC_ROOT="$root"
	trap 'rm -rf "$SC_ROOT"' EXIT
	ok() { echo "ok    $*"; }
	bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
	git="$(lab_tool git)"
	src="$root/vzfreebsd"
	mkdir -p "$src"
	printf 'FREEBSD_URL=https://example.invalid/src.git\nFREEBSD_BRANCH=main\n' \
		> "$src/freebsd.lock"
	printf 'FREEBSD_COMMIT=0123456789abcdef\n' >> "$src/freebsd.lock"
	"$git" -C "$src" init -q
	"$git" -C "$src" -c user.name=lab -c user.email=lab@localhost add freebsd.lock
	"$git" -C "$src" -c user.name=lab -c user.email=lab@localhost -c commit.gpgsign=false \
		commit -q -m lab
	export MACHMAN_LAB_VZFREEBSD="$src" MACHMAN_LAB_CACHE="$root/cache"
	out="$("$HERE/import.sh" path)"
	rc=$?
	[ "$rc" = 3 ] && [ "$out" = "vzfreebsd image not built (make image in $src)" ] \
		&& ok "absent: exit 3, '$out'" || bad "absent: exit $rc, '$out'"
	mkdir -p "$src/out" "$src/work"
	dd if=/dev/zero of="$src/out/vzfreebsd.raw" bs=1 count=0 seek=67108864 2>/dev/null
	printf 'lab' | dd of="$src/out/vzfreebsd.raw" bs=1 seek=4096 conv=notrunc 2>/dev/null
	: > "$src/work/.lock"
	out="$("$HERE/import.sh" path)"
	rc=$?
	[ "$rc" = 3 ] && [ "$out" = "vzfreebsd is being built ($src/work/.lock present)" ] \
		&& ok "building: exit 3, '$out'" || bad "building: exit $rc, '$out'"
	rm -f "$src/work/.lock"
	listing() {
		find "$src" -ls | awk '{ $1 = ""; print }' | sort
		stat -f '%m %z' "$src/.git/index"
	}
	before="$(listing)"
	p1="$("$HERE/import.sh" path)" || bad "import failed"
	if [ -f "$p1" ] && [ "$(json_field "${p1%.raw}.json" git_head)" \
		= "$("$git" -C "$src" rev-parse HEAD)" ] \
		&& [ "$(json_field "${p1%.raw}.json" freebsd_commit)" = 0123456789abcdef ] \
		&& [ "$(stat -f %Lp "$p1")" = 444 ]; then
		ok "imported $(basename "$p1") with the git head and the freebsd.lock pin"
	else
		bad "import record: $(cat "${p1%.raw}.json" 2>/dev/null)"
	fi
	p2="$("$HERE/import.sh" path)"
	[ "$p2" = "$p1" ] && [ "$(stat -f %i "$p1")" = "$(stat -f %i "$p2")" ] \
		&& ok "unchanged: same clone, same inode" || bad "unchanged source re-imported"
	after="$(listing)"
	[ "$before" = "$after" ] && ok "the source tree and .git/index are untouched" \
		|| bad "the source changed: $(diff <(echo "$before") <(echo "$after") | head -4)"
	touch -t 203001010000 "$src/out/vzfreebsd.raw"
	p3="$("$HERE/import.sh" path)"
	if [ -f "$p3" ] && [ "$(json_field "${p3%.raw}.json" source_mtime)" \
		= "$(stat -f %m "$src/out/vzfreebsd.raw")" ] \
		&& [ "$(ls "$root/cache/vzfreebsd"/*.json | wc -l | tr -d ' ')" = 1 ]; then
		ok "touched: re-imported, one record left"
	else
		bad "touched source not re-imported"
	fi
	"$HERE/import.sh" status >/dev/null && ok "status prints the record" || bad "status"
	unset MACHMAN_LAB_VZFREEBSD MACHMAN_LAB_CACHE
	if [ "$fails" = 0 ]; then echo "import.sh --self-check: all ok"
	else echo "import.sh --self-check: $fails FAILED"; fi
	[ "$fails" = 0 ]
}

case "${1:-}" in
path) cmd_path ;;
status) cmd_status ;;
--self-check) self_check ;;
*) usage ;;
esac; exit $?
