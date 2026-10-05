# Sandbox helpers shared by scripts/test.sh and scripts/lab.sh.
# Sourced, never executed; functions are prefixed sandbox_; never set -e or exit here.

# sandbox_create <prefix> <xcount>: a fresh /tmp/<prefix>.<token> root with the suite id,
# data dir and fake home of a test run. Sets SANDBOX_ROOT, SANDBOX_TOKEN, SANDBOX_SUITE.
sandbox_create() {
	# /tmp, not $TMPDIR: socket paths built on the run dir must stay under sun_path's 104 bytes.
	SANDBOX_ROOT="$(mktemp -d "/tmp/$1.$(printf 'X%.0s' $(seq 1 "$2"))")"
	SANDBOX_TOKEN="${SANDBOX_ROOT##*.}"
	SANDBOX_SUITE="com.gustaffranzen.Machman.test-$SANDBOX_TOKEN"
	mkdir -p "$SANDBOX_ROOT/data" "$SANDBOX_ROOT/home"
	echo "$$" > "$SANDBOX_ROOT/.owner"
}

# sandbox_cleanup <root>: remove the root and everything derived from its token.
sandbox_cleanup() (
	# Every path below derives from the token; do nothing on any surprise.
	[[ "$1" =~ ^/tmp/(mmt|mml)\.[A-Za-z0-9]+$ ]] || return 0
	# Best effort: under set -e the first failing rm would skip every later sweep and turn a
	# green run into exit 1 — the script exits with the tests' own status, not cleanup's.
	set +e
	base="${1##*/}"
	token="${base#*.}"
	suite="com.gustaffranzen.Machman.test-$token"
	temp="$(getconf DARWIN_USER_TEMP_DIR)"
	rm -rf "$1"
	rm -rf "${temp}${suite}"                              # MachmanPaths.runtimeDir
	rm -f "${temp}_private_tmp_${base}_"*                 # SwiftPM locks named after the fake home
	rm -rf "$HOME/Library/Application Support/$suite"     # defaultDataDir in the real home
	rm -f "$HOME/Library/Preferences/$suite"*.plist       # any defaults domain under the suite
)

# sandbox_is_stale <root>: return 0 when the run that made <root> is gone, 1 to keep it.
sandbox_is_stale() {
	local pid
	# A kept root (lab.sh --keep) survives for a day, whoever owned it.
	if [[ -f "$1/.keep" && -z "$(find "$1/.keep" -mmin +1440 2>/dev/null)" ]]; then
		return 1
	fi
	if [[ -f "$1/.owner" ]]; then
		pid="$(head -n1 "$1/.owner" | tr -cd '0-9')"
		if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
			return 1
		fi
		return 0
	fi
	# No owner: it may be a live run of an older test.sh in another worktree, so only a root
	# older than a day is stale.
	[[ -n "$(find "$1" -maxdepth 0 -mmin +1440 2>/dev/null)" ]]
}

# sandbox_sweep_root <root>: clean <root> when it is a sandbox name and its run is gone.
# A caller may define sandbox_presweep_hook <root> to stop what the dead run left running.
sandbox_sweep_root() {
	[[ -d "$1" && "$1" =~ ^/tmp/(mmt|mml)\.[A-Za-z0-9]+$ ]] || return 0
	sandbox_is_stale "$1" || return 0
	if declare -F sandbox_presweep_hook >/dev/null; then
		sandbox_presweep_hook "$1"
	fi
	sandbox_cleanup "$1"
}

# sandbox_sweep_stale <prefix>...: silently sweep every /tmp/<prefix>.* of a dead run.
sandbox_sweep_stale() {
	local prefix dir
	for prefix in "$@"; do
		for dir in /tmp/"$prefix".*; do
			[[ -d "$dir" ]] && sandbox_sweep_root "$dir"
		done
	done
	return 0
}

# sandbox_refuse_main_checkout <repo>: the main checkout (a .git directory, not a linked
# worktree's .git file) builds the products the user runs; no lab run may start there.
sandbox_refuse_main_checkout() {
	if [[ -d "$1/.git" ]]; then
		echo "lab.sh: refusing to run in the main checkout ($1): it builds the products you" \
			"run; use a linked worktree (git worktree add)" >&2
		return 64
	fi
	return 0
}

# sandbox_review_fix_dir <repo>: the orchestrator's review-fix dir (slot locks, xcbuild),
# reached through the git common dir; prints nothing when this clone has none.
sandbox_review_fix_dir() {
	local common
	common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
		return 0
	common="${common%/.git}/.worktrees/machmand-refactor/docs/local/review-fix"
	[[ -d "$common" ]] && echo "$common"
	return 0
}

# sandbox_lab_cache: the fixture cache (several GB, outside the repo).
sandbox_lab_cache() {
	echo "${MACHMAN_LAB_CACHE:-$HOME/Library/Caches/com.gustaffranzen.Machman.lab}"
}

# sandbox_slot_dir <repo>: where the machine-wide lab slot lives.
sandbox_slot_dir() {
	local rf
	if [[ -n "${MACHMAN_LAB_SLOT_DIR:-}" ]]; then
		echo "$MACHMAN_LAB_SLOT_DIR"
		return 0
	fi
	rf="$(sandbox_review_fix_dir "$1")"
	if [[ -n "$rf" && -d "$rf/locks" ]]; then
		echo "$rf/locks"
	else
		echo "$(sandbox_lab_cache)/locks"
	fi
}

# sandbox_take_slot <dir> <name>: mkdir lock + owner file, stale-pid reclaim. Sets
# SANDBOX_SLOT. SANDBOX_SLOT_WAIT=0 returns 75 instead of waiting.
sandbox_take_slot() {
	local dir="$1" name="$2" slot owner
	slot="$dir/$name"
	mkdir -p "$dir"
	while :; do
		if [[ -d "$slot" ]]; then
			if [[ -f "$slot/owner" ]]; then
				owner="$(cut -d' ' -f1 "$slot/owner" 2>/dev/null | tr -cd '0-9')"
				if [[ -z "$owner" ]] || ! kill -0 "$owner" 2>/dev/null; then
					rm -rf "$slot"
				fi
			elif [[ -n "$(find "$slot" -maxdepth 0 -mmin +10 2>/dev/null)" ]]; then
				rm -rf "$slot"
			fi
		fi
		if mkdir "$slot" 2>/dev/null; then
			echo "$$ ${SANDBOX_SLOT_LABEL:-$PWD}" > "$slot/owner"
			SANDBOX_SLOT="$slot"
			return 0
		fi
		if [[ "${SANDBOX_SLOT_WAIT:-1}" == 0 ]]; then
			return 75
		fi
		echo "lab.sh: the lab slot is held by $(cat "$slot/owner" 2>/dev/null), waiting 30 s" >&2
		sleep 30
	done
}

# sandbox_release_slot: drop the slot, only when this process owns it.
sandbox_release_slot() {
	[[ -n "${SANDBOX_SLOT:-}" && -f "$SANDBOX_SLOT/owner" ]] || return 0
	if [[ "$(cut -d' ' -f1 "$SANDBOX_SLOT/owner" 2>/dev/null)" == "$$" ]]; then
		rm -rf "$SANDBOX_SLOT"
	fi
	return 0
}

# sandbox_path_budget <suite>: <temp><suite>/tty-<8 hex>.sock must fit sun_path (103 bytes
# plus NUL); see MachmanPaths.serialSocketPath. 18 = "/tty-" + 8 hex + ".sock".
sandbox_path_budget() {
	local t
	t="$(getconf DARWIN_USER_TEMP_DIR)"
	(( ${#t} + ${#1} + 18 <= 103 ))
}
