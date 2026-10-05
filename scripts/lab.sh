#!/bin/bash
#
# The Machman lab: real Debug agent and vmhost processes of THIS worktree's build, under a
# .test-<token> suite, driven over their socket by MachmanKit's MachmanLabTests target.
#
#   scripts/lab.sh [--quick|--full|--guests] [--launchd] [--filter REGEX] [--keep] [--out DIR]
#                  [--no-build]
#   scripts/lab.sh --self-check | --doctor | --help
#
#   --quick     tiers harness,smoke (the lab agent and the Alpine fixture, no L3 guests)
#   (no mode)   tiers harness,smoke,l2
#   --full      tiers harness,smoke,l2,l3 (everything, incl. the guest OSes)
#   --guests    tiers harness,l3
#   --launchd   adds the launchd tier (test-labelled jobs in gui/$UID, always booted out)
#   --filter    matches Swift Testing ids (type and function names, unanchored), never
#               display names; without a mode it runs every tier
#   --keep      keep the sandbox for a day (after the run: lab: kept <root>)
#   --out DIR   copy report, logs and transcripts to DIR (absolute; git-ignored if in the repo)
#   --no-build  skip the xcodebuild and swift build steps
#   --self-check  prove the lab's own machinery: script self-checks, then the harness tests
#                 with every audit armed
#   --doctor    check tools, cache, fixtures and seams; runs nothing, writes nothing
#
# Exit codes: 0 green, 1 tests failed, 3 audit breach, 64 usage or refused, 69 unavailable.
#
# Environment lab.sh sets for the tests: MACHMAN_LAB=1, MACHMAN_LAB_RUN (the sandbox root),
# MACHMAN_LAB_REPO, MACHMAN_LAB_TIERS, MACHMAN_LAB_SEAMS, MACHMAN_LAB_PRODUCTS,
# MACHMAN_LAB_CACHE, MACHMAN_LAB_LOG, MACHMAN_LAB_ANSWERS, MACHMAN_LAB_AGENT_CONTROL, plus
# MACHMAN_SUITE_ID / MACHMAN_DATA_DIR / CFFIXED_USER_HOME. Overrides: MACHMAN_LAB_CACHE,
# MACHMAN_LAB_SLOT_DIR, MACHMAN_LAB_XCBUILD.
#
# Run dir /tmp/mml.<4-char token>: data/ home/ pids/ logs/ transcripts/ scopes/<NN>/ report/
# (watch/summary.txt, snapshot-summary.txt, worktree.txt, swift-test.log).
#
# One lab run machine-wide: the slot <review-fix>/locks/lab.1 (or <cache>/locks/lab.1).
#
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd -P)"
pkg="$repo/MachmanKit"
source "$repo/scripts/lib/sandbox.sh"

usage() {
	awk 'NR >= 3 { if ($0 ~ /^set -euo/) exit; sub(/^# ?/, ""); print }' "$0"
}

mode=run
tiers_mode=default
launchd=0
filter=""
keep=0
out=""
build=1
products=""
root=""
token=""
suite=""

while (($#)); do
	case "$1" in
	--help | -h) usage; exit 0 ;;
	--self-check) mode=selfcheck ;;
	--doctor) mode=doctor ;;
	--quick) tiers_mode=quick ;;
	--full) tiers_mode=full ;;
	--guests) tiers_mode=guests ;;
	--launchd) launchd=1 ;;
	--filter) filter="${2:?--filter needs a regex}"; shift ;;
	--out) out="${2:?--out needs a directory}"; shift ;;
	--keep) keep=1 ;;
	--no-build) build=0 ;;
	*) echo "lab.sh: unknown argument $1 (see --help)" >&2; exit 64 ;;
	esac
	shift
done

# --- helpers ---------------------------------------------------------------------------

# lab_export <tiers> <seams>: the contract the tests (and the agent they launch) read.
lab_export() {
	export MACHMAN_SUITE_ID="$suite" MACHMAN_DATA_DIR="$root/data" CFFIXED_USER_HOME="$root/home"
	export TMPDIR
	TMPDIR="$(getconf DARWIN_USER_TEMP_DIR)"
	export MACHMAN_LAB=1 MACHMAN_LAB_RUN="$root" MACHMAN_LAB_REPO="$repo"
	export MACHMAN_LAB_TIERS="$1" MACHMAN_LAB_SEAMS="$2" MACHMAN_LAB_PRODUCTS="${products:-}"
	export MACHMAN_LAB_CACHE
	export MACHMAN_LAB_LOG="$root/logs/unified.ndjson"
	export MACHMAN_LAB_ANSWERS="$root/answers.json" MACHMAN_LAB_AGENT_CONTROL="$root/agent.ctl"
	unset SSH_AUTH_SOCK SSH_ASKPASS
}

# lab_token_pids <token>: same-uid processes whose argv or environment name this run's suite
# or sandbox (exact token). Never this script's own shells, nor the ps and awk doing the scan.
lab_token_pids() {
	ps -axwwE -o pid=,command= -U "$(id -u)" 2>/dev/null | awk -v t="$1" -v me="$$" -v pp="$PPID" '
		{
			if ($1 == me || $1 == pp) next
			if ($2 ~ /(^|\/)(ps|awk)$/) next
			if ($2 ~ /(^|\/)bash$/ && $0 ~ /lab\.sh/) next
			if ($0 ~ ("Machman\\.test-" t "([^A-Za-z0-9]|$)") ||
				$0 ~ ("/mml\\." t "([^A-Za-z0-9]|$)")) print $1
		}'
}

# lab_pidfile_pids <root>: live pids named by <root>/pids/*.pid.
lab_pidfile_pids() {
	local f pid
	for f in "$1"/pids/*.pid; do
		[[ -f "$f" ]] || continue
		pid="$(head -n1 "$f" | tr -cd '0-9')"
		[[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && echo "$pid"
	done
	return 0
}

# lab_kill_pids <pid>...: TERM, wait up to 5 s, then KILL the survivors.
lab_kill_pids() {
	local p n alive
	local pids=()
	for p in "$@"; do
		[[ -n "$p" && "$p" != "$$" && "$p" != "$PPID" ]] || continue
		kill -TERM "$p" 2>/dev/null && pids+=("$p")
	done
	((${#pids[@]})) || return 0
	for n in 1 2 3 4 5 6 7 8 9 10; do
		alive=0
		for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
		((alive)) || return 0
		sleep 0.5
	done
	for p in "${pids[@]}"; do kill -KILL "$p" 2>/dev/null || true; done
	return 0
}

# lab_bootout_jobs <token>: test-labelled launchd jobs of this run, never any other label.
lab_bootout_jobs() {
	local label
	for label in $(launchctl list 2>/dev/null |
		awk -v p="com.gustaffranzen.Machman.test-$1." 'index($3, p) == 1 { print $3 }'); do
		launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
	done
	return 0
}

# lab_r3td_sweeps <root>: r3-td's QEMU and sshd sweeps, when those scripts exist.
lab_r3td_sweeps() {
	[[ -x "$repo/scripts/lab/qemu/run.sh" ]] && "$repo/scripts/lab/qemu/run.sh" sweep "$1" || true
	[[ -x "$repo/scripts/lab/sshd/sshd.sh" ]] && "$repo/scripts/lab/sshd/sshd.sh" sweep "$1" || true
	return 0
}

# lab_presweep <root>: stop what a dead /tmp/mml.* run left behind (token scan only: pids in
# its pid files may have been reused since).
lab_presweep() {
	local t
	[[ "$1" == /tmp/mml.* ]] || return 0
	t="${1##*.}"
	lab_kill_pids $(lab_token_pids "$t")
	lab_r3td_sweeps "$1"
	lab_bootout_jobs "$t"
	return 0
}
sandbox_presweep_hook() { lab_presweep "$1"; }

lab_finish() {
	local status=$?
	set +e
	if [[ -n "${root:-}" && -d "${root:-}" ]]; then
		lab_kill_pids $( { lab_pidfile_pids "$root"; lab_token_pids "${token:-}"; } | sort -u)
		lab_r3td_sweeps "$root"
		lab_bootout_jobs "${token:-}"
		if ((${keep:-0})); then
			touch "$root/.keep"
			echo "lab: kept $root"
		else
			sandbox_cleanup "$root"
		fi
	fi
	sandbox_release_slot
	exit "$status"
}

# --- self-check ------------------------------------------------------------------------

lab_selfcheck() {
	local failures=0 teststatus=0
	sandbox_refuse_main_checkout "$repo" || exit 64
	MACHMAN_LAB_CACHE="$(sandbox_lab_cache)"
	mkdir -p "$MACHMAN_LAB_CACHE"
	sandbox_sweep_stale mml mmt
	((build)) && swift build --build-tests --package-path "$pkg"
	SANDBOX_SLOT_LABEL="$repo" sandbox_take_slot "$(sandbox_slot_dir "$repo")" lab.1
	sandbox_create mml 4
	root="$SANDBOX_ROOT"
	token="$SANDBOX_TOKEN"
	suite="$SANDBOX_SUITE"
	trap lab_finish EXIT
	if ! sandbox_path_budget "$suite"; then
		echo "lab.sh: the console socket paths of $suite would exceed sun_path" >&2
		exit 69
	fi
	mkdir -p "$root"/{pids,logs,transcripts,scopes,report}
	echo '{}' > "$root/answers.json"
	lab_export harness 0
	echo "lab: sandbox $root (suite $suite)"
	"$repo/scripts/lib/sandbox-selfcheck.sh" || failures=$((failures + $?))
	"$repo/scripts/lab/fetch.sh" --self-check || failures=$((failures + $?))
	"$repo/scripts/lab/guests/alpine/build.sh" --self-check || failures=$((failures + $?))
	set +e
	swift test --skip-build --disable-xctest --no-parallel --package-path "$pkg" \
		--filter 'MachmanLabTests\.' 2>&1 | tee "$root/report/swift-test.log"
	teststatus=${PIPESTATUS[0]}
	set -e
	((failures || teststatus)) && exit 1
	exit 0
}

case "$mode" in
selfcheck) lab_selfcheck ;;
*)
	echo "lab.sh: $mode isn't available yet" >&2
	exit 64
	;;
esac
