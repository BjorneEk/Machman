#!/bin/bash
#
# forget-builds.sh: takes Machman's app bundles out of the Launch Services database.
#
# Xcode registers every app it builds with Launch Services, and deleting the build folder
# leaves the record behind: a removed worktree's DerivedData stays registered for good, and
# macOS keeps it among the copies it may open for a bundle id. Unregister a build before
# deleting it, and sweep what was deleted without that.
#
#   scripts/forget-builds.sh <dir>…      unregister every .app under each dir (nested ones too);
#                                        run it BEFORE deleting a worktree or DerivedData folder
#   scripts/forget-builds.sh --stale     unregister every registered Machman*.app whose path is gone
#   scripts/forget-builds.sh --list      the registered Machman*.app paths, gone ones marked
#   scripts/forget-builds.sh --self-check  registers, deletes and forgets a throwaway bundle
#
# Only Launch Services records change; no file is touched.
#
set -euo pipefail

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

usage() {
	awk 'NR >= 3 { if ($0 ~ /^set -euo/) exit; sub(/^# ?/, ""); print }' "$0"
	exit 64
}

# registered: every registered app path whose bundle name starts with "Machman", one per line.
registered() {
	"$LSREGISTER" -dump 2>/dev/null |
		sed -n -E 's/^path: +(.*\/Machman[^/]*\.app)( \(0x[0-9a-f]+\))?$/\1/p' | sort -u
}

forget() { # forget <path>: unregister one app path, present or gone
	"$LSREGISTER" -u "$1" >/dev/null 2>&1 || true
}

stale() {
	local p n=0
	while IFS= read -r p; do
		[[ -e "$p" ]] && continue
		forget "$p"
		n=$((n + 1))
	done < <(registered)
	echo "forgot $n stale Machman app registration(s); $(registered | wc -l | tr -d ' ') remain"
}

dirs() {
	local d app n=0
	for d in "$@"; do
		[[ -d "$d" ]] || { echo "forget-builds.sh: no folder at $d" >&2; exit 66; }
		while IFS= read -r -d '' app; do
			forget "$app"
			n=$((n + 1))
		done < <(find "$d" -type d -name '*.app' -print0)
	done
	echo "unregistered $n app bundle(s); the folders can go now"
}

# listed <path>: is <path> among the registered Machman apps? (The whole dump is read first:
# a grep -q that stops early would SIGPIPE the dump and fail the pipeline.)
listed() {
	local all
	all="$(registered)"
	grep -qxF "$1" <<<"$all"
}

selfcheck() {
	local root app fails=0
	root="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/forget-builds.XXXXXX")" && pwd -P)"
	trap "rm -rf '$root'" EXIT
	app="$root/MachmanForgetBuildsCheck.app"
	bundle() { # a throwaway app bundle with an id no real app has
		mkdir -p "$app/Contents/MacOS"
		cat >"$app/Contents/Info.plist" <<-EOF
			<?xml version="1.0" encoding="UTF-8"?>
			<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
			<plist version="1.0"><dict>
			<key>CFBundleIdentifier</key><string>invalid.machman.forget-builds.$$</string>
			<key>CFBundleName</key><string>MachmanForgetBuildsCheck</string>
			<key>CFBundlePackageType</key><string>APPL</string>
			</dict></plist>
		EOF
		"$LSREGISTER" -f "$app"
	}
	check() {
		if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
	}
	bundle
	check "a registered build is listed" listed "$app"
	rm -rf "$app"
	check "a deleted build stays registered (what --stale is for)" listed "$app"
	forget "$app"
	check "forgetting a gone path drops it" eval '! listed "$app"'
	bundle
	dirs "$root" >/dev/null
	check "a folder's builds are unregistered before it goes" eval '! listed "$app"'
	return "$fails"
}

case "${1:-}" in
--stale) stale ;;
--list)
	registered | while IFS= read -r p; do
		if [[ -e "$p" ]]; then echo "     $p"; else echo "gone $p"; fi
	done
	;;
--self-check) selfcheck ;;
"" | -h | --help) usage ;;
-*) usage ;;
*) dirs "$@" ;;
esac
