#!/bin/bash
#
# Offscreen renders of the desktop's views — the ONLY supported way to run MachmanRender.
#
#   scripts/render.sh --list                           the scenes: name, widths, summary
#   scripts/render.sh --out DIR [SCENE-GLOB ...]       every matching scene, light + dark
#   scripts/render.sh --out DIR --scheme dark --widths 320 'inspector.*'
#
# Builds the tool (debug: it reaches the views through @testable import), then runs it in a
# throwaway sandbox — its own suite id, data dir and fake home, removed on exit — so a run
# can never read or write the .dev or Release libraries or files under the real ~/Library.
# Defaults are the exception: cfprefsd serves them from the real home, so the tool's own
# domain (MachmanRender, which @AppStorage reads) is shared by every run. The tool refuses to
# start while it holds anything and fails a run that leaves something there; scenes never
# write UserDefaults.standard, and nobody runs `defaults write MachmanRender`. The tool
# draws into windows that are never ordered on screen, under a prohibited activation policy:
# nothing on screen, no Dock icon, no focus change, no daemon; it stops if a scene breaks that.
#
# Fidelity: layout and text are the app's; colours nearly so. Switch and checkbox "on" states
# lack the accent fill. Glass and materials draw in their Reduce Transparency form (opaque,
# hairline edge); capsule outlines get a short tick at each end. In window.* scenes the split
# view's glass columns are flat composites of the real column views, the traffic lights are
# hidden and a 1 px line marks the inspector edge. Alerts, confirmation dialogs and open/save
# panels cannot render. Text follows the locale ("34,36 GB").
#
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
pkg="$repo/MachmanKit"

swift build --package-path "$pkg" --product MachmanRender >&2
bin="$(swift build --package-path "$pkg" --show-bin-path)/MachmanRender"

root="$(mktemp -d "${TMPDIR:-/tmp}/machman-render.XXXXXX")"
token="${root##*.}"
suite="com.gustaffranzen.Machman.render-$token"
mkdir -p "$root/data" "$root/home"

cleanup() {
	# Every path below derives from the token minted above; do nothing on any surprise.
	[[ "$root" == */machman-render.* && "$suite" == com.gustaffranzen.Machman.render-* ]] \
		|| return 0
	# Best effort, as in test.sh: one failing rm must not skip the sweeps after it.
	set +e
	rm -rf "$root"
	rm -rf "$(getconf DARWIN_USER_TEMP_DIR)$suite"            # MachmanPaths.runtimeDir
	# Nothing lands here today (scenes pass their stores explicit URLs); a future scene
	# that builds a default-URL store would, under the render suite.
	rm -rf "$HOME/Library/Application Support/$suite"          # defaultDataDir in the real home
	rm -f "$HOME/Library/Preferences/$suite"*.plist            # any defaults domain under the suite
}
trap cleanup EXIT

env MACHMAN_SUITE_ID="$suite" MACHMAN_DATA_DIR="$root/data" CFFIXED_USER_HOME="$root/home" \
	"$bin" "$@"
