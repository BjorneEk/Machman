#!/bin/sh
# Dev-loop assembler: the same concatenation EmbeddedScript.assembled does in Swift,
# for shellcheck and the docker harness. Output: GuestScripts/dist/install.sh (gitignored).
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT="$HERE/dist/install.sh"
mkdir -p "$HERE/dist"

: > "$OUT"
for part in "$HERE"/setup/[0-9][0-9]-*.sh; do
	cat "$part" >> "$OUT"
	printf '\n' >> "$OUT"
done
chmod 755 "$OUT"

for sh_bin in "sh -n" "bash --posix -n" "ksh -n"; do
	# shellcheck disable=SC2086
	if $sh_bin "$OUT" 2>&1; then
		echo "parse ok: $sh_bin"
	else
		echo "PARSE FAILED under: $sh_bin" >&2
		exit 1
	fi
done
echo "assembled: $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"
