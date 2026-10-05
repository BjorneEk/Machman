#!/bin/bash
#
# Compile the host-quiet audit helper (hostwatch) into the lab cache and print its path.
# Cached by the sources and the compiler version; a second call compiles nothing.
#
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
repo="$(cd "$here/../../.." && pwd -P)"
CACHE="${MACHMAN_LAB_CACHE:-$repo/scripts/lab/cache}"

key="$( { cat "$here"/hostwatch/*.swift; xcrun swiftc --version 2>&1; } | shasum -a 256 | cut -c1-12)"
out="$CACHE/bin/hostwatch-$key"
if [[ ! -x "$out" ]]; then
	mkdir -p "$CACHE/bin"
	log="$(mktemp /tmp/hostwatch-build.XXXXXX)"
	if ! xcrun swiftc -O -swift-version 5 -module-name hostwatch -o "$out.tmp.$$" \
		"$here"/hostwatch/*.swift >"$log" 2>&1; then
		cat "$log"
		rm -f "$log" "$out.tmp.$$"
		exit 1
	fi
	rm -f "$log"
	mv "$out.tmp.$$" "$out"
fi
echo "$out"
