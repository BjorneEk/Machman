# Sourced (bash 3.2) by the lab's guest scripts: qemu/run.sh, qemu/seed.sh, qemu/prepare.sh,
# sshd/sshd.sh and guests/*/*.sh. Tool resolution, the refusals every lab script shares, and
# the run-root and cache rules. Step 11 swaps the run-root, slot and main-checkout pieces for
# scripts/lib/sandbox.sh; until then a run root is an explicit --run argument.

LAB_QEMU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$LAB_QEMU_DIR/.." && pwd)"
LAB_REPO="$(cd "$LAB_DIR/../.." && pwd)"

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

# Refuse the main checkout (production builds there): its git common dir is its own .git.
lab_refuse_main_checkout() {
	local git common own
	git="$(lab_tool git)"
	common="$(cd "$LAB_REPO" && cd "$("$git" rev-parse --git-common-dir 2>/dev/null)" \
		2>/dev/null && pwd -P)" || lab_die 64 "$LAB_REPO is not a git checkout."
	own="$(cd "$LAB_REPO/.git" 2>/dev/null && pwd -P)" || own=""
	[ "$common" != "$own" ] || lab_die 64 "refusing to run from the main checkout ($LAB_REPO)."
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

# lab_new_root: a fresh run root for a self-check (step 11: sandbox_create).
lab_new_root() {
	mktemp -d /tmp/mml.XXXX
}

