#!/bin/bash
#
# One-time dev environment setup for the machmand-refactor worktree.
#
#  - Points the refactor apps' data dir at <worktree>/.machman via user defaults, which
#    covers Finder/Spotlight launches (the Xcode scheme's MACHMAN_DATA_DIR covers Xcode runs).
#  - Clones the production Debian + macOS VMs into .machman/ with APFS clonefile (instant,
#    space-shared; falls back to a plain copy across volumes).
#
# Reads ~/.machman only. Never writes to it. Refuses to clone while the production
# Machman app is running (cloning a live disk image gives a torn copy).
#
set -euo pipefail

WORKTREE="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="$WORKTREE/.machman"
PROD_DIR="$HOME/.machman"
VMS=("Debian" "macOS")

defaults write Gustaf-Franzen.Machman-desktop MachmanDataDir "$DATA_DIR"
defaults write Gustaf-Franzen.Machmand MachmanDataDir "$DATA_DIR"   # future daemon
echo "MachmanDataDir default -> $DATA_DIR"

mkdir -p "$DATA_DIR"

# pgrep name matching misses app-bundle processes on macOS; match the binary path instead.
if pgrep -f "/Machman\.app/Contents/MacOS/Machman$" >/dev/null; then
	echo "error: Machman.app is running — quit it (and its VMs) before cloning" >&2
	exit 1
fi

for vm in "${VMS[@]}"; do
	src="$PROD_DIR/$vm"
	dst="$DATA_DIR/$vm"
	if [ ! -d "$src" ]; then
		echo "skip: $src does not exist" >&2
		continue
	fi
	if [ -e "$dst" ]; then
		echo "skip: $dst already exists"
		continue
	fi
	# Second layer: any open file inside the VM dir (disk.raw etc.) means a live VM.
	if lsof +D "$src" >/dev/null 2>&1; then
		echo "error: $vm has open files (VM running?) — not cloning it" >&2
		continue
	fi
	if ! cp -Rc "$src" "$dst" 2>/dev/null; then
		rm -rf "$dst"        # partial clone attempt inside the dev dir only
		cp -R "$src" "$dst"
	fi
	# A cloned config may carry a stale "running" state; the dev copy starts stopped.
	sed -i '' 's/"state" : "running"/"state" : "stopped"/' "$dst/config"
	echo "cloned $vm -> $dst"
done
echo "done"
