#!/bin/bash
# A lab run of its own for a command started outside scripts/lab.sh that boots guests (e.g.
# scripts/guest-regress/run.sh --backend qemu, a POSIX sh script): the stale sweep, the
# machine-wide slot, a fresh /tmp/mml.<token> root as MACHMAN_LAB_RUN; swept, removed and
# released when the command ends (common.sh lab_session).
#
#   lab-session.sh [--keep] <command…>
set -u
# shellcheck source=common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
[ $# -gt 0 ] || { sed -n '7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }
lab_session "$@"; exit $?
