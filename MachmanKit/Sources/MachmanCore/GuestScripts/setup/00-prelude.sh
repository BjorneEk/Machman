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
#   sh install.sh --uninstall    remove its configuration (it names what stays)
#
# It is allowed not to succeed. It is not allowed to fail without saying why: every
# feature is probed before it is offered, every action is a named step, and whatever
# happens is reported back to Machman.
set -eu

# Raised when a fix must reach guests that ran an older copy: the inspector offers a re-run
# to every guest that reported a lower one (4: link-safe, mode-keeping edits, rc.local
# re-enabled; 5: a boot-time report copy kept in the guest, console re-runs that keep every
# login, state that remembers unselected features, Void and NetBSD consoles, notes; 6:
# 'ssh mac' ahead of the user's Host * defaults, OpenBSD consoles, NetBSD's user-mount
# sysctl checked, the share's link mounted with a trailing slash; 7: systemd logins owned
# only where a run enabled them and hvc0's automatic one read so, ASCII prose and lines
# folded to an ASCII console, a re-run that leaves init alone under its own console, every
# sshfs host folder through a trailing slash, NetBSD's bare address and its user-mount
# sysctl kept for the next boot, a copy's own machine id).
SCRIPT_VERSION=7

# ------------------------------------------------------------------- payload bootstrap ----

PAYLOAD_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ ! -r "$PAYLOAD_DIR/machman.env" ]; then
	echo "machman.env is missing next to this script — run the copy Machman put in the" >&2
	echo "share, not install.sh on its own." >&2
	exit 3
fi
# Set only by the boot-time copy's own machman.env (report_copy_install): where its
# reports go — the share's drop-box — and that it may only report.
BOOT_REPORT_DIR=""
# Set only in a copy's payloads until the copy first reports: the VM it was copied from (its
# marker) — a copy of a guest that never ran Guest Setup has no state to say so itself.
COPY_OF=""
# The POSIX cksum of this copy's script and files as Machman served them (payload_check);
# older payloads and the boot-time copy carry none.
SETUP_CKSUM=""
# VM_NAME, MARKER, REPORT_DIR_NAME, MOUNT_ROOT, SHARE_ROOT, SHARE_TAG, SHARE_HOST_PATH,
# BOOT_MODE, CONSOLE_COUNT, UART_COUNT, HOST_USER, HOST_NAME, HOST_LOCAL
. "$PAYLOAD_DIR/machman.env"
REPORT_DIR="${BOOT_REPORT_DIR:-$PAYLOAD_DIR/../$REPORT_DIR_NAME}"
# Resolved when it exists, so everything the user sees is a real path.
if _resolved="$(CDPATH= cd -- "$REPORT_DIR" 2>/dev/null && pwd)"; then
	REPORT_DIR="$_resolved"
fi
# Per-mount hand-off (kind<TAB>name<TAB>hostpath lines); optional — older payloads and
# VMs without mounts ship none.
MOUNTS_LIST="$PAYLOAD_DIR/mounts.list"
