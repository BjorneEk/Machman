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
