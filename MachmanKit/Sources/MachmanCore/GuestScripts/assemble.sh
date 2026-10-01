#!/bin/sh
# Dev-loop assembler: the same concatenation GuestSetupScript.assembled does in Swift, for
# shellcheck and the docker harness — byte for byte (EmbeddedScriptTests holds it there),
# so a line number in the output is the guest's line number. Each part is followed by a
# newline only when it lacks a final one.
#   sh assemble.sh [output]      default GuestScripts/dist/install.sh (gitignored)
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT="${1:-$HERE/dist/install.sh}"
mkdir -p "$(dirname -- "$OUT")"

: > "$OUT"
for part in "$HERE"/setup/[0-9][0-9]-*.sh; do
	cat "$part" >> "$OUT"
	[ -z "$(tail -c 1 "$part")" ] || printf '\n' >> "$OUT"
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
