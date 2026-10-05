#!/bin/bash
#
# Headless test runner for MachmanKit — the ONLY supported way to run the suite.
#
#   scripts/test.sh [swift test args]     e.g. --filter WireFixtureTests
#   scripts/test.sh --self-check          prove the sandbox guard refuses unsandboxed runs
#
# Never launches an app or touches a live daemon. Every run gets its own suite id
# (com.gustaffranzen.Machman.test-<token>), a scratch data dir and a fake home under
# /tmp/mmt.<token>, all removed on exit — so a run can neither resolve the .dev / Release
# Machman paths nor leave anything behind, and two runs can go in parallel. The contract is
# enforced in-process by MachmanKit/Tests/MachmanTestGuard (a load-time constructor).
#
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
pkg="$repo/MachmanKit"
source "$repo/scripts/lib/sandbox.sh"
mode=run
if [[ "${1:-}" == "--self-check" ]]; then
	mode=selfcheck
	shift
fi

# Build in the caller's environment: the fake home below would cold-start SwiftPM's caches.
swift build --build-tests --package-path "$pkg"

sandbox_create mmt 6
root="$SANDBOX_ROOT"
token="$SANDBOX_TOKEN"
suite="$SANDBOX_SUITE"
trap 'sandbox_cleanup "$root"' EXIT


if [[ "$mode" == selfcheck ]]; then
	failures=0
	# expect_refusal <label> [VAR=value ...]: a run with ONLY those variables must be refused.
	# The filter matches no test: if the guard is dead, the run starts (and FAILs below) but
	# executes nothing — a dead guard must never run the suite against the .dev paths or the
	# real home, which is exactly what several of these environments would point it at.
	expect_refusal() {
		local label="$1"
		shift
		local out
		if out="$(env -i PATH="$PATH" HOME="$HOME" "$@" \
			swift test --skip-build --disable-xctest --package-path "$pkg" \
			--filter __machman_guard_selfcheck__ 2>&1)"; then
			echo "FAIL  $label: the test process started, the guard did not refuse it"
			failures=$((failures + 1))
		elif grep -q "MachmanTestGuard: refusing" <<<"$out"; then
			echo "ok    $label"
		else
			echo "FAIL  $label: failed, but not through the guard"
			failures=$((failures + 1))
		fi
	}
	data="$root/data"
	home="$root/home"
	expect_refusal "no suite id"
	expect_refusal "dev suite" \
		MACHMAN_SUITE_ID=com.gustaffranzen.Machman.dev MACHMAN_DATA_DIR="$data" \
		CFFIXED_USER_HOME="$home"
	expect_refusal "release suite" \
		MACHMAN_SUITE_ID=com.gustaffranzen.Machman MACHMAN_DATA_DIR="$data" \
		CFFIXED_USER_HOME="$home"
	expect_refusal "no data dir" MACHMAN_SUITE_ID="$suite" CFFIXED_USER_HOME="$home"
	# /var/empty: neither the real home nor writable, so no run can leak into it.
	expect_refusal "data dir without the run token" MACHMAN_SUITE_ID="$suite" \
		MACHMAN_DATA_DIR=/var/empty/x CFFIXED_USER_HOME="$home"
	expect_refusal "no fake home" MACHMAN_SUITE_ID="$suite" MACHMAN_DATA_DIR="$data"
	exit "$failures"
fi

status=0
env MACHMAN_SUITE_ID="$suite" MACHMAN_DATA_DIR="$root/data" CFFIXED_USER_HOME="$root/home" \
	swift test --skip-build --disable-xctest --package-path "$pkg" "$@" || status=$?

# Anything a test wrote where the real ~/.ssh or ~/Library/LaunchAgents would be landed in the
# fake home instead: surface it (SwiftPM's own .swiftpm and Library/Caches there are expected).
leaks="$(find "$root/home" -mindepth 1 \( -path '*/.ssh' -o -path '*/Library/LaunchAgents' \
	-o -path '*/Library/Application Support' \) 2>/dev/null || true)"
if [[ -n "$leaks" ]]; then
	echo "test.sh: tests wrote into the fake home:" >&2
	echo "$leaks" >&2
	status=1
fi
exit "$status"
