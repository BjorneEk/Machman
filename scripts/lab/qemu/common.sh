# Sourced (bash 3.2) by the lab's guest scripts: qemu/run.sh, qemu/seed.sh, qemu/prepare.sh,
# sshd/sshd.sh and guests/*/*.sh. Tool resolution, the refusals every lab script shares, and
# the run-root and cache rules. Run roots, the machine-wide slot, the stale sweep and the
# main-checkout refusal are scripts/lib/sandbox.sh's (shared with lab.sh and test.sh): a
# script that boots guests runs inside scripts/lab.sh's run (MACHMAN_LAB_RUN), or takes a lab
# run of its own with lab_session.

LAB_QEMU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$LAB_QEMU_DIR/.." && pwd)"
LAB_REPO="$(cd "$LAB_DIR/../.." && pwd)"
# shellcheck source=../../lib/sandbox.sh
. "$LAB_REPO/scripts/lib/sandbox.sh"

# lab_die <code> <sentence>: one sentence on stderr, then exit.
lab_die() {
	local code="$1"
	shift
	echo "$(basename "$0"): $*" >&2
	exit "$code"
}

# The Command Line Tools shims (/usr/bin/python3, /usr/bin/git) open an installer dialog when
# no developer directory exists: never call one then.
lab_shim_ok() { # <path>
	case "$1" in
	/usr/bin/*) xcode-select -p >/dev/null 2>&1 ;;
	*) return 0 ;;
	esac
}

# lab_tool <name>: the resolved path of python3 or git, or exit 69.
lab_tool() {
	local p
	p="$(command -v "$1" 2>/dev/null)" || lab_die 69 "$1 is not installed."
	lab_shim_ok "$p" || lab_die 69 "$p is the Command Line Tools shim and no developer dir is set."
	printf '%s\n' "$p"
}

# Refuse the main checkout (production builds there; its .git is a directory, a linked
# worktree's a file).
lab_refuse_main_checkout() {
	sandbox_refuse_main_checkout "$LAB_REPO" 2>/dev/null \
		|| lab_die 64 "refusing to run from the main checkout ($LAB_REPO)."
}

# A run root is /tmp/mml.<token> (the lab's sandbox), never anything else.
lab_is_run_root() { # <path>
	case "$1" in
	/tmp/mml.*|/private/tmp/mml.*) ;;
	*) return 1 ;;
	esac
	local tok="${1##*/mml.}"
	[ -n "$tok" ] && [ "${tok//[A-Za-z0-9]/}" = "" ]
}

lab_check_run_root() { # <path>
	lab_is_run_root "$1" || lab_die 64 "the run root must be /tmp/mml.<token>, not '$1'."
	[ -d "$1" ] || lab_die 64 "the run root $1 does not exist."
}

# The lab cache (T3, C-1): MACHMAN_LAB_CACHE, else this worktree's gitignored scripts/lab/cache.
lab_cache_dir() {
	printf '%s\n' "${MACHMAN_LAB_CACHE:-$LAB_REPO/scripts/lab/cache}"
}

# A free TCP port on 127.0.0.1 (the kernel's pick; never 22).
lab_free_port() {
	"$(lab_tool python3)" -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])'
}

# lab_pid_of <pidfile>: the first integer in it, or nothing.
lab_pid_of() {
	[ -f "$1" ] || return 1
	local p
	p="$(head -n 1 "$1" 2>/dev/null | tr -cd '0-9')"
	[ -n "$p" ] && printf '%s\n' "$p"
}

# lab_pid_is <pid> <command name>: alive and its executable's basename is <name>.
lab_pid_is() {
	local c
	c="$(ps -p "$1" -o comm= 2>/dev/null)" || return 1
	[ "$(basename "$c")" = "$2" ]
}

# lab_new_root: a fresh /tmp/mml.<token> root (sandbox.sh), owned by this script's process
# (a dead owner's root is swept by the next lab run).
lab_new_root() {
	sandbox_create mml 4
	printf '%s\n' "$SANDBOX_ROOT"
}

# lab_in_run: 0 inside a live lab run — MACHMAN_LAB_RUN names a run root whose owner (lab.sh,
# or a lab_session) is alive and holds the slot.
lab_in_run() {
	local r="${MACHMAN_LAB_RUN:-}" p
	lab_is_run_root "$r" && [ -d "$r" ] || return 1
	p="$(lab_pid_of "$r/.owner")" || return 1
	kill -0 "$p" 2>/dev/null
}

# lab_token_pids <token>: same-uid processes whose command line or environment names the run
# /tmp/mml.<token> or its suite (everything a run starts carries MACHMAN_LAB_RUN) — never this
# shell, nor the ps and awk doing the scan.
lab_token_pids() {
	ps -axwwE -o pid=,command= -U "$(id -u)" 2>/dev/null | awk -v t="$1" -v me="$$" '
		$1 == me { next }
		$2 ~ /(^|\/)(ps|awk)$/ { next }
		$0 ~ ("/mml\\." t "([^A-Za-z0-9]|$)") || $0 ~ ("Machman\\.test-" t "([^A-Za-z0-9]|$)") {
			print $1
		}'
}

# lab_kill_tree <pid>: <pid> and its descendants — frozen top-down first, so none starts
# another while the tree is collected, then terminated.
lab_kill_tree() {
	local c
	kill -STOP "$1" 2>/dev/null || return 0
	for c in $(pgrep -P "$1" 2>/dev/null); do lab_kill_tree "$c"; done
	kill -TERM "$1" 2>/dev/null
	kill -CONT "$1" 2>/dev/null
	return 0
}

# lab_end_run <root>: stop what a run started — every process carrying its token (ps shows
# the environment of most, not of every platform binary: a session also kills its command's
# process tree), then its QEMU guests (daemonized, so swept by pid file) and its lab sshd.
lab_end_run() {
	local p
	for p in $(lab_token_pids "${1##*.}"); do kill -TERM "$p" 2>/dev/null; done
	"$LAB_QEMU_DIR/run.sh" sweep "$1" >/dev/null 2>&1
	"$LAB_DIR/sshd/sshd.sh" sweep "$1" >/dev/null 2>&1
	return 0
}

# What a dead run left behind (sandbox_sweep_stale calls this per stale root).
sandbox_presweep_hook() { lab_end_run "$1"; }

# lab_session [--keep] <command…>: <command> inside a lab run of its own, for a script started
# outside scripts/lab.sh that boots guests: the stale sweep, the machine-wide slot (it waits
# while another run holds it), a fresh /tmp/mml.<token> root exported as MACHMAN_LAB_RUN. When
# this script exits, however it ends, everything the run started is stopped, the root removed
# (kept for a day with --keep, or for its logs when the command failed) and the slot released.
# The command runs in the background (stdin /dev/null) so a signal reaches the traps at once.
lab_session() {
	local keep=0
	[ "${1:-}" = --keep ] && { keep=1; shift; }
	lab_refuse_main_checkout
	sandbox_sweep_stale mml
	SANDBOX_SLOT_LABEL="$LAB_REPO ($(basename "$0"))" \
		sandbox_take_slot "$(sandbox_slot_dir "$LAB_REPO")" lab.1
	LAB_SESSION_KEEP="$keep"
	sandbox_create mml 4
	LAB_SESSION_ROOT="$SANDBOX_ROOT"
	mkdir -p "$LAB_SESSION_ROOT/pids"
	trap lab_session_end EXIT
	trap 'exit 130' INT TERM HUP ALRM USR1 USR2
	MACHMAN_LAB_RUN="$LAB_SESSION_ROOT" "$@" &
	LAB_SESSION_CHILD=$!
	wait "$LAB_SESSION_CHILD"
}

lab_session_end() {
	local rc=$?
	[ -n "${LAB_SESSION_CHILD:-}" ] && lab_kill_tree "$LAB_SESSION_CHILD"
	lab_end_run "$LAB_SESSION_ROOT"
	if [ "$LAB_SESSION_KEEP" = 1 ] || [ "$rc" != 0 ]; then
		touch "$LAB_SESSION_ROOT/.keep"
		echo "lab: kept $LAB_SESSION_ROOT$([ "$rc" = 0 ] || echo " (exit $rc)")" >&2
	else
		sandbox_cleanup "$LAB_SESSION_ROOT"
	fi
	sandbox_release_slot
	exit "$rc"
}

