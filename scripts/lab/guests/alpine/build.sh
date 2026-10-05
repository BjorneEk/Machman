#!/bin/bash
#
# The Alpine lab guest: the pinned netboot kernel and initramfs plus the lab overlay
# (lab-init, lab-hidlog, the modloop).
#
#   scripts/lab/guests/alpine/build.sh path          build (cached by content) and print
#                                                    kernel=, initramfs= and version= lines
#   scripts/lab/guests/alpine/build.sh --self-check
#
# Boot with: console=hvc0 rdinit=/lab-init  (knobs: lab.noshell, lab.nohid).
#
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(cd "$here/../../../.." && pwd -P)"
fetch="$repo/scripts/lab/fetch.sh"
CACHE="${MACHMAN_LAB_CACHE:-$repo/scripts/lab/cache}"
export MACHMAN_LAB_CACHE="$CACHE"

cmd_path() {
	local kernel base modloop key out tmp
	kernel="$("$fetch" path alpine-3.24-aarch64-kernel)"
	base="$("$fetch" path alpine-3.24-aarch64-initramfs)"
	modloop="$("$fetch" path alpine-3.24-aarch64-modloop)"
	key="$(cat "$base.stamp" "$modloop.stamp" "$here/lab-init" "$here/lab-hidlog" |
		shasum -a 256 | cut -c1-12)"
	out="$CACHE/built/alpine-lab-initramfs-$key"
	if [[ ! -f "$out" ]]; then
		mkdir -p "$CACHE/built" "$CACHE/tmp"
		tmp="$CACHE/tmp/alpine-build.$$"
		rm -rf "$tmp"
		mkdir -p "$tmp/ov/lab"
		install -m 0755 "$here/lab-init" "$tmp/ov/lab-init"
		install -m 0755 "$here/lab-hidlog" "$tmp/ov/lab/lab-hidlog"
		cp -c "$modloop" "$tmp/ov/lab/modloop" 2>/dev/null || cp "$modloop" "$tmp/ov/lab/modloop"
		chmod 0644 "$tmp/ov/lab/modloop"
		(cd "$tmp/ov" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort |
			cpio -o -H newc -R 0:0 2>/dev/null) | gzip -9n >"$tmp/overlay.gz"
		cat "$base" "$tmp/overlay.gz" >"$tmp/out"
		stat -f %z "$base" >"$out.base-bytes"
		gzip -dc "$base" | cpio -t 2>/dev/null |
			sed -n 's|^usr/lib/modules/\([^/]*\)/.*|\1|p;s|^lib/modules/\([^/]*\)/.*|\1|p' |
			head -1 >"$out.version"
		mv "$tmp/out" "$out"
		chmod 0444 "$out"
		rm -rf "$tmp"
	fi
	echo "kernel=$kernel"
	echo "initramfs=$out"
	echo "version=$(cat "$out.version")"
}

selfcheck() {
	local failures=0 sc fx base_bytes out a b
	ok() { echo "ok   $1"; }
	fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
	sc="$(mktemp -d /tmp/mml-alpine.XXXXXX)"
	trap 'rm -rf "$sc"' EXIT

	# 1 syntax under sh and ksh
	if sh -n "$here/lab-init" && sh -n "$here/lab-hidlog" &&
		ksh -n "$here/lab-init" && ksh -n "$here/lab-hidlog"; then
		ok "syntax: lab-init and lab-hidlog parse under sh and ksh"
	else
		fail "syntax: lab-init and lab-hidlog parse under sh and ksh" "a shell refused them"
	fi

	# 2 the HID parser under sh and ksh
	{
		head -c 16 /dev/zero
		printf '\001\000\036\000\001\000\000\000'
		head -c 16 /dev/zero
		printf '\000\000\000\000\000\000\000\000'
	} >"$sc/events"
	for shell in sh ksh; do
		got="$($shell "$here/lab-hidlog" --parse "$sc/events")"
		if [[ "$got" == $'HID file 1 30 1\nHID file 0 0 0' ]]; then
			ok "hidlog: $shell decodes two input events"
		else
			fail "hidlog: $shell decodes two input events" "$got"
		fi
	done

	if ! "$fetch" --verify alpine-3.24-aarch64-kernel alpine-3.24-aarch64-initramfs \
		alpine-3.24-aarch64-modloop >/dev/null 2>&1; then
		echo "skip path/prefix/overlay checks (fixtures not fetched)"
		exit "$failures"
	fi

	# 3 path twice gives the same file, untouched
	a="$(cmd_path | sed -n 's/^initramfs=//p')"
	b="$(stat -f %m "$a")"
	sleep 1
	if [[ "$(cmd_path | sed -n 's/^initramfs=//p')" == "$a" && "$(stat -f %m "$a")" == "$b" ]]; then
		ok "path: a second call reuses the built initramfs"
	else
		fail "path: a second call reuses the built initramfs" "it was rebuilt"
	fi

	# 4 the original initramfs is a byte-exact prefix
	base_bytes="$(cat "$a.base-bytes")"
	fx="$("$fetch" path alpine-3.24-aarch64-initramfs)"
	if head -c "$base_bytes" "$a" | cmp -s - "$fx"; then
		ok "overlay: the Alpine initramfs is a byte-exact prefix"
	else
		fail "overlay: the Alpine initramfs is a byte-exact prefix" "it differs"
	fi

	# 5 the overlay lists lab-init, lab-hidlog and the modloop
	out="$(tail -c +$((base_bytes + 1)) "$a" | gzip -dc | cpio -itv 2>/dev/null)"
	if grep -qE '^-rwxr-xr-x .* lab-init$' <<<"$out" &&
		grep -qE '^-rwxr-xr-x .* lab/lab-hidlog$' <<<"$out" &&
		grep -qE ' lab/modloop$' <<<"$out"; then
		ok "overlay: lab-init, lab/lab-hidlog and lab/modloop are in it"
	else
		fail "overlay: lab-init, lab/lab-hidlog and lab/modloop are in it" "$out"
	fi
	exit "$failures"
}

case "${1:-}" in
path) cmd_path ;;
--self-check) selfcheck ;;
*) awk 'NR >= 3 { if ($0 ~ /^set -euo/) exit; sub(/^# ?/, ""); print }' "$0" >&2; exit 64 ;;
esac
