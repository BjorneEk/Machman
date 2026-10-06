#!/bin/bash
# The vzfreebsd image (FreeBSD patched to run under Apple VZ) the lab boots: a copy kept in the
# lab cache by hand, nothing fetched or built. The L3 vzfreebsd tests run when it is there and
# skip, naming this script, when it isn't.
#
#   import.sh <image.raw>  copy a vzfreebsd image (a vzfreebsd checkout's work/out/release.raw)
#                          to <cache>/vzfreebsd/vzfreebsd.raw (an APFS clone, 0444) and record
#                          its source, sha256 and manifest (<image>.json) in vzfreebsd.json
#   import.sh path         the cached image; exit 3 with "vzfreebsd image missing (...)"
#   import.sh status       the cached image's record
#   import.sh --self-check
#
# The source is only read: a clone (cp -c, no copy fallback); never make, never git.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../qemu/common.sh
. "$HERE/../../qemu/common.sh"

usage() {
	sed -n '6,11p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 64
}

dest_dir() { printf '%s/vzfreebsd\n' "$(lab_cache_dir)"; }

cmd_import() {
	local img="$1" dest part sum
	[ -f "$img" ] || lab_die 64 "no image at $img."
	dest="$(dest_dir)"
	mkdir -p "$dest"
	part="$dest/.part-$$"
	rm -f "$part" "$part.json"
	cp -c "$img" "$part" 2>/dev/null \
		|| lab_die 1 "cannot clone $img into $dest (cp -c): the lab cache must be on its volume."
	sum="$(shasum -a 256 "$part" | cut -d' ' -f1)"
	"$(lab_tool python3)" - "$part.json" "$img" "$sum" "$(stat -f %z "$img")" <<'EOF'
import json, os, sys, time
out, img, sha, size = sys.argv[1:5]
manifest = None
try:
	with open(os.path.splitext(img)[0] + ".json") as f:
		manifest = json.load(f)
except (OSError, ValueError):
	pass
rec = {"source": img, "size": int(size), "sha256": sha, "manifest": manifest,
	"imported_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
with open(out, "w") as f:
	json.dump(rec, f, indent=1)
	f.write("\n")
EOF
	chmod 444 "$part"
	rm -f "$dest/vzfreebsd.raw"
	mv -f "$part" "$dest/vzfreebsd.raw"
	mv -f "$part.json" "$dest/vzfreebsd.json"
	printf '%s\n' "$dest/vzfreebsd.raw"
}

cmd_path() {
	local img
	img="$(dest_dir)/vzfreebsd.raw"
	if [ ! -f "$img" ]; then
		echo "vzfreebsd image missing (scripts/lab/guests/vzfreebsd/import.sh <image.raw>" \
			"copies one to $img)"
		exit 3
	fi
	printf '%s\n' "$img"
}

cmd_status() {
	local j
	j="$(dest_dir)/vzfreebsd.json"
	if [ -f "$j" ] && [ -f "$(dest_dir)/vzfreebsd.raw" ]; then
		cat "$j"
	else
		echo "no vzfreebsd image in $(dest_dir)"
		return 1
	fi
}

self_check() {
	local root fails=0 src out rc p1 p2 before after want
	root="$(lab_new_root)"
	SC_ROOT="$root"
	trap 'rm -rf "$SC_ROOT"' EXIT
	ok() { echo "ok    $*"; }
	bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
	export MACHMAN_LAB_CACHE="$root/cache"
	out="$("$HERE/import.sh" path)"
	rc=$?
	want="vzfreebsd image missing (scripts/lab/guests/vzfreebsd/import.sh <image.raw> copies"
	want="$want one to $root/cache/vzfreebsd/vzfreebsd.raw)"
	[ "$rc" = 3 ] && [ "$out" = "$want" ] && ok "absent: exit 3, '$out'" \
		|| bad "absent: exit $rc, '$out'"
	src="$root/vzfreebsd/work/out"
	mkdir -p "$src"
	dd if=/dev/zero of="$src/release.raw" bs=1 count=0 seek=67108864 2>/dev/null
	printf 'lab' | dd of="$src/release.raw" bs=1 seek=4096 conv=notrunc 2>/dev/null
	printf '{"image": "release", "vzfreebsd": {"commit": "98d08ee"}}\n' > "$src/release.json"
	listing() { find "$root/vzfreebsd" -ls | awk '{ $1 = ""; print }' | sort; }
	p1="$("$HERE/import.sh" "$src/release.raw")" || bad "import failed"
	if [ "$p1" = "$root/cache/vzfreebsd/vzfreebsd.raw" ] && [ "$(stat -f %Lp "$p1")" = 444 ] \
		&& cmp -s "$p1" "$src/release.raw" \
		&& "$(lab_tool python3)" -c 'import json, sys
r = json.load(open(sys.argv[1]))
sys.exit(0 if r["manifest"]["vzfreebsd"]["commit"] == "98d08ee" and len(r["sha256"]) == 64
	and r["source"] == sys.argv[2] else 1)' "${p1%.raw}.json" "$src/release.raw"; then
		ok "imported a read-only clone with its source, sha256 and manifest"
	else
		bad "import: $(cat "${p1%.raw}.json" 2>/dev/null)"
	fi
	[ "$("$HERE/import.sh" path)" = "$p1" ] && ok "path prints the cached image" \
		|| bad "path after the import"
	printf 'again' | dd of="$src/release.raw" bs=1 seek=8192 conv=notrunc 2>/dev/null
	before="$(listing)"
	p2="$("$HERE/import.sh" "$src/release.raw")" || bad "re-import failed"
	[ "$p2" = "$p1" ] && cmp -s "$p2" "$src/release.raw" \
		&& [ "$(find "$root/cache/vzfreebsd" -type f | wc -l | tr -d ' ')" = 2 ] \
		&& ok "a re-import replaces the image, one image and one record left" \
		|| bad "re-import: $(ls -a "$root/cache/vzfreebsd")"
	after="$(listing)"
	[ "$before" = "$after" ] && ok "the source is untouched" \
		|| bad "the source changed: $(diff <(echo "$before") <(echo "$after") | head -4)"
	"$HERE/import.sh" status >/dev/null && ok "status prints the record" || bad "status"
	out="$("$HERE/import.sh" "$root/nowhere.raw" 2>&1)"
	rc=$?
	[ "$rc" = 64 ] && ok "a missing source: exit 64" || bad "missing source: exit $rc, '$out'"
	unset MACHMAN_LAB_CACHE
	if [ "$fails" = 0 ]; then echo "import.sh --self-check: all ok"
	else echo "import.sh --self-check: $fails FAILED"; fi
	[ "$fails" = 0 ]
}

case "${1:-}" in
path) cmd_path ;;
status) cmd_status ;;
--self-check) self_check ;;
"" | -*) usage ;;
*) cmd_import "$1" ;;
esac; exit $?
