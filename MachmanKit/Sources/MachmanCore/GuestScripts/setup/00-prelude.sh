#!/bin/sh
# === machman-setup: 00-prelude ===
# Machman guest setup — one script for everything configurable from inside this guest:
# console logins, kernel console output, SSH, guest -> host SSH, sshfs, and boot
# automounts. Machman ASSEMBLES this file from modules and rewrites it in the share at
# every VM start; run this copy, not one you moved elsewhere.
#
#   sh install.sh                interactive — asks only what it cannot work out
#   sh install.sh -n             print the plan and change nothing
#   sh install.sh -y --ssh       unattended
#   sh install.sh --uninstall    remove everything it installed
#
# It is allowed not to succeed. It is not allowed to fail without saying why: every
# feature is probed before it is offered, every action is a named step, and whatever
# happens is reported back to Machman.
set -eu

SCRIPT_VERSION=3

# ------------------------------------------------------------------- payload bootstrap ----

PAYLOAD_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ ! -r "$PAYLOAD_DIR/machman.env" ]; then
	echo "machman.env is missing next to this script — run the copy Machman put in the" >&2
	echo "share, not install.sh on its own." >&2
	exit 3
fi
# VM_NAME, MARKER, REPORT_DIR_NAME, MOUNT_ROOT, SHARE_ROOT, SHARE_TAG, SHARE_HOST_PATH,
# BOOT_MODE, CONSOLE_COUNT, UART_COUNT, HOST_USER, HOST_NAME, HOST_LOCAL
. "$PAYLOAD_DIR/machman.env"
REPORT_DIR="$PAYLOAD_DIR/../$REPORT_DIR_NAME"
# Resolved when it exists, so everything the user sees is a real path.
if _resolved="$(CDPATH= cd -- "$REPORT_DIR" 2>/dev/null && pwd)"; then
	REPORT_DIR="$_resolved"
fi
# Per-mount hand-off (kind<TAB>name<TAB>hostpath lines); optional — older payloads and
# VMs without mounts ship none.
MOUNTS_LIST="$PAYLOAD_DIR/mounts.list"
