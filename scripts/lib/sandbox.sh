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
