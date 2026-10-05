#!/bin/bash
#
# The Machman lab: real Debug agent and vmhost processes of THIS worktree's build, under a
# .test-<token> suite, driven over their socket by MachmanKit's MachmanLabTests target.
#
#   scripts/lab.sh [--quick|--full|--guests|--harness] [--launchd] [--filter REGEX] [--keep] [--out DIR]
#                  [--no-build]
#   scripts/lab.sh --self-check | --doctor | --help
#
#   --quick     tiers harness,smoke (the lab agent and the Alpine fixture, no L3 guests)
#   (no mode)   tiers harness,smoke,l2
#   --full      tiers harness,smoke,l2,l3 (everything, incl. the guest OSes)
#   --guests    tiers harness,l3
#   --harness   tiers harness only: the lab's own machinery, boots nothing, needs no slot
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
	--harness) tiers_mode=harness ;;
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

# lab_detach_images <root>: force-detach any disk image attached from under <root>.
lab_detach_images() {
	local dev
	for dev in $(hdiutil info -plist 2>/dev/null | plutil -convert json -o - - 2>/dev/null |
		python3 -c '
import json, sys
root = sys.argv[1] + "/"
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for image in doc.get("images", []):
    if str(image.get("image-path", "")).startswith(root):
        for entity in image.get("system-entities", []):
            dev = entity.get("dev-entry", "")
            if dev and not dev[-1:].isalpha() and "s" not in dev.rsplit("disk", 1)[-1]:
                print(dev)
' "$1"); do
		hdiutil detach -force "$dev" >/dev/null 2>&1 || true
	done
	return 0
}

WATCHPID=""
LOGPID=""

lab_stop_helpers() {
	local p
	[[ -n "$WATCHPID" && -n "$root" ]] && touch "$root/report/watch/stop" 2>/dev/null
	for p in $WATCHPID $LOGPID; do
		kill -TERM "$p" 2>/dev/null
	done
	WATCHPID=""
	LOGPID=""
}

lab_finish() {
	local status=$?
	set +e
	lab_stop_helpers
	if [[ -n "${root:-}" && -d "${root:-}" ]]; then
		lab_kill_pids $( { lab_pidfile_pids "$root"; lab_token_pids "${token:-}"; } | sort -u)
		lab_r3td_sweeps "$root"
		lab_bootout_jobs "${token:-}"
		lab_detach_images "$root"
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

# lab_products_dir: this worktree's Debug products (default DerivedData); prints the dir.
lab_products_dir() {
	local info dd ws
	for info in "$HOME"/Library/Developer/Xcode/DerivedData/Machman-*/info.plist; do
		[[ -f "$info" ]] || continue
		ws="$(plutil -extract WorkspacePath raw -o - "$info" 2>/dev/null)" || continue
		if [[ "$ws" == "$repo/Machman.xcodeproj" ]]; then
			dd="$(dirname "$info")/Build/Products/Debug"
			[[ -d "$dd" ]] && { echo "$dd"; return 0; }
		fi
	done
	(cd "$repo" && xcodebuild -project Machman.xcodeproj -scheme MachmanDesktop \
		-configuration Debug -showBuildSettings 2>/dev/null |
		sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1)
}

# The literals r3-tb's seams log; a build without them would show a menu-bar item and
# alerts when the lab launches it. The Debug app code lives in Contents/MacOS/*.debug.dylib,
# so every file there is searched.
LAB_SEAM_MARKER_AGENT="test mode: agent under"
LAB_SEAM_MARKER_VMHOST="test mode: no window for"

lab_has_marker() {  # lab_has_marker <app> <marker>
	local f
	for f in "$1"/Contents/MacOS/*; do
		[[ -f "$f" ]] && strings -a "$f" 2>/dev/null | grep -qF "$2" && return 0
	done
	return 1
}

lab_seams_present() {  # lab_seams_present <products dir>
	lab_has_marker "$1/MachmanDesktop.app/Contents/Library/LoginItems/MachmanAgent.app" \
		"$LAB_SEAM_MARKER_AGENT" &&
		lab_has_marker "$1/MachmanDesktop.app/Contents/Library/MachmanVMHost.app" \
			"$LAB_SEAM_MARKER_VMHOST"
}

lab_check_products() {  # lab_check_products <products dir>: exit 69 unless both apps are there
	local agent="$1/MachmanDesktop.app/Contents/Library/LoginItems/MachmanAgent.app"
	local host="$1/MachmanDesktop.app/Contents/Library/MachmanVMHost.app"
	[[ "$(plutil -extract CFBundleIdentifier raw -o - "$agent/Contents/Info.plist" 2>/dev/null)" \
		== com.gustaffranzen.Machman.dev.agent &&
		"$(plutil -extract CFBundleIdentifier raw -o - "$host/Contents/Info.plist" 2>/dev/null)" \
		== com.gustaffranzen.Machman.dev.vmhost ]] || {
		echo "lab.sh: no Debug MachmanDesktop.app with its agent and vmhost under '$1'" \
			"(build it first)" >&2
		exit 69
	}
}

lab_tiers() {
	local t
	case "$tiers_mode" in
	quick) t="harness,smoke" ;;
	full) t="harness,smoke,l2,l3" ;;
	guests) t="harness,l3" ;;
	harness) t="harness" ;;
	*) if [[ -n "$filter" ]]; then t="harness,smoke,l2,l3"; else t="harness,smoke,l2"; fi ;;
	esac
	((launchd)) && t="$t,launchd"
	echo "$t"
}

# lab_run <tiers> <seams-needed 0|1>: build, arm the audits, run the tests, sweep, report.
# In --self-check the products and the slot are skipped (tiers = harness).
lab_run() {
	local tiers="$1" seams=0 xcb filt hw ts breaches=0 warns=0 f line report
	local teststatus="${3:-0}" watchstatus=0 need_slot=0 selfcheck="${2:-0}"
	sandbox_refuse_main_checkout "$repo" || exit 64
	if [[ -n "$out" ]]; then
		[[ "$out" == /* ]] || { echo "lab.sh: --out must be an absolute path" >&2; exit 64; }
		if [[ "$out" == "$repo"/* ]] && ! git -C "$repo" check-ignore -q "$out"; then
			echo "lab.sh: --out $out is inside the repo and not git-ignored" >&2
			exit 64
		fi
	fi
	MACHMAN_LAB_CACHE="$(sandbox_lab_cache)"
	mkdir -p "$MACHMAN_LAB_CACHE"
	sandbox_sweep_stale mml mmt
	if ((build)); then
		if ((!selfcheck)); then
			xcb="${MACHMAN_LAB_XCBUILD:-}"
			if [[ -z "$xcb" ]]; then
				xcb="$(sandbox_review_fix_dir "$repo")/bin/xcbuild"
				[[ -x "$xcb" ]] || xcb=""
			fi
			if [[ -n "$xcb" ]]; then
				"$xcb" "$repo"
			else
				(cd "$repo" && set -o pipefail && xcodebuild build -project Machman.xcodeproj \
					-scheme MachmanDesktop -destination 'platform=macOS' 2>&1 |
					grep -E "error:|BUILD (SUCCEEDED|FAILED)")
			fi
		fi
		swift build --build-tests --package-path "$pkg"
	fi
	if ((!selfcheck)); then
		products="$(lab_products_dir)"
		lab_check_products "$products"
		echo "lab: products $products"
		if lab_seams_present "$products"; then
			seams=1
		elif [[ "$tiers" == *smoke* || "$tiers" == *l2* || "$tiers" == *launchd* ]]; then
			echo "lab.sh: this build lacks the test-mode seams (r3-tb): the agent tiers would" \
				"show a menu-bar item and alerts — refusing" >&2
			exit 69
		else
			echo "lab: WARN this build lacks the test-mode seams (r3-tb); agent tiers would refuse"
		fi
	fi
	hw="$("$repo/scripts/lab/audit/build.sh")"
	if [[ "$tiers" == *smoke* || "$tiers" == *l2* ]]; then
		"$repo/scripts/lab/guests/alpine/build.sh" path >/dev/null
	fi
	if [[ "$tiers" == *l3* ]]; then
		"$repo/scripts/lab/fetch.sh" fetch --lock "$repo/scripts/lab/fixtures.lock" >/dev/null
	fi
	[[ "$tiers" == *smoke* || "$tiers" == *l2* || "$tiers" == *l3* || "$tiers" == *launchd* ]] &&
		need_slot=1
	trap 'exit 130' INT TERM HUP
	if ((need_slot)); then
		SANDBOX_SLOT_LABEL="$repo" sandbox_take_slot "$(sandbox_slot_dir "$repo")" lab.1
	fi
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
	git -C "$repo" status --porcelain=v1 --untracked-files=all > "$root/report/git-before.txt"
	env -u CFFIXED_USER_HOME -u MACHMAN_DATA_DIR -u MACHMAN_SUITE_ID \
		"$hw" snapshot --token "$token" --out "$root/report/snapshot-before.json"
	lab_export "$tiers" "$seams"
	echo "lab: sandbox $root (suite $suite) tiers $tiers"
	# r3-td's lab sshd: its host key, which the agent pins under test mode.
	if [[ -x "$repo/scripts/lab/sshd/sshd.sh" ]]; then
		"$repo/scripts/lab/sshd/sshd.sh" keygen "$root" || true
		MACHMAN_LAB_SSHD_HOSTKEY="$("$repo/scripts/lab/sshd/sshd.sh" hostkey "$root")" || true
		export MACHMAN_LAB_SSHD_HOSTKEY
	fi
	# The unified log of the suite, as ndjson (a launched agent's stdio isn't captured).
	: > "$MACHMAN_LAB_LOG"
	log stream --style ndjson --level default --predicate "subsystem == \"$suite\"" \
		> "$MACHMAN_LAB_LOG" 2> "$root/logs/logstream.err" &
	LOGPID=$!
	# The stream takes a moment to attach: repeat the probe line until it comes back.
	local waited=0
	until grep -qF "lab: log stream attached $token" "$MACHMAN_LAB_LOG" 2>/dev/null; do
		((waited % 2 == 0)) &&
			"$hw" logprobe --suite "$suite" --text "lab: log stream attached $token"
		sleep 0.5
		waited=$((waited + 1))
		if ((waited > 40)); then
			echo "lab.sh: log stream did not deliver the probe line (is this user an admin?)" >&2
			exit 69
		fi
	done
	"$hw" watch --token "$token" --run "$root" --out "$root/report/watch" &
	WATCHPID=$!
	waited=0
	until [[ -f "$root/report/watch/started" ]]; do
		sleep 0.5
		waited=$((waited + 1))
		if ((waited > 20)); then
			echo "lab.sh: the host audit did not start" >&2
			exit 69
		fi
	done
	echo "lab: audits armed"
	filt='MachmanLabTests\.'
	[[ -n "$filter" ]] && filt="MachmanLabTests\\..*($filter)"
	# In the background and waited for, so an interrupt reaches the trap at once.
	rm -f "$root/report/test-status"
	{
		set +e
		swift test --skip-build --disable-xctest --no-parallel --package-path "$pkg" \
			--filter "$filt" 2>&1
		echo $? > "$root/report/test-status"
	} | tee "$root/report/swift-test.log" &
	wait $!
	ts="$(cat "$root/report/test-status" 2>/dev/null || echo 1)"
	((ts != 0)) && teststatus=1
	# Sweep, then stop the audits and compare.
	lab_kill_pids $( { lab_pidfile_pids "$root"; lab_token_pids "$token"; } | sort -u |
		grep -vxF -e "$WATCHPID" -e "$LOGPID")
	lab_r3td_sweeps "$root"
	lab_bootout_jobs "$token"
	lab_detach_images "$root"
	touch "$root/report/watch/stop"
	waited=0
	while kill -0 "$WATCHPID" 2>/dev/null && ((waited < 30)); do
		sleep 0.5
		waited=$((waited + 1))
	done
	if kill -0 "$WATCHPID" 2>/dev/null; then kill -TERM "$WATCHPID" 2>/dev/null || true; fi
	wait "$WATCHPID" 2>/dev/null || watchstatus=$?
	WATCHPID=""
	kill "$LOGPID" 2>/dev/null || true
	wait "$LOGPID" 2>/dev/null || true
	LOGPID=""
	env -u CFFIXED_USER_HOME -u MACHMAN_DATA_DIR -u MACHMAN_SUITE_ID \
		"$hw" snapshot --token "$token" --out "$root/report/snapshot-after.json"
	"$hw" diff --before "$root/report/snapshot-before.json" \
		--after "$root/report/snapshot-after.json" \
		--non-lab "$root/report/watch/non-lab-machman.txt" --token "$token" \
		--out "$root/report/snapshot-summary.txt" || true
	git -C "$repo" status --porcelain=v1 --untracked-files=all > "$root/report/git-after.txt"
	if cmp -s "$root/report/git-before.txt" "$root/report/git-after.txt"; then
		echo "OK worktree" > "$root/report/worktree.txt"
	else
		{
			echo "BREACH worktree the run changed the worktree"
			diff "$root/report/git-before.txt" "$root/report/git-after.txt"
		} > "$root/report/worktree.txt" || true
	fi
	report="$root/report"
	for f in "$report/watch/summary.txt" "$report/snapshot-summary.txt" "$report/worktree.txt"; do
		[[ -f "$f" ]] || continue
		while IFS= read -r line; do
			case "$line" in
			BREACH*) breaches=$((breaches + 1)); echo "lab: audit $line" ;;
			WARN*) warns=$((warns + 1)); echo "lab: audit $line" ;;
			esac
		done < "$f"
	done
	echo "lab: audits: $breaches breaches, $warns warnings"
	if ((teststatus)); then
		echo "lab: tests FAILED (swift test exit $ts)"
	else
		echo "lab: tests passed"
	fi
	if [[ -n "$out" ]]; then
		local dest="$out/lab-$(date +%Y%m%d-%H%M%S)-$token"
		mkdir -p "$dest"
		cp -R "$report" "$root/logs" "$root/transcripts" "$dest/"
		echo "lab: report copied to $dest"
	fi
	((breaches)) && exit 3
	((teststatus)) && exit 1
	exit 0
}

case "$mode" in
selfcheck)
	sandbox_refuse_main_checkout "$repo" || exit 64
	tiers_mode=harness
	# The script self-checks run BEFORE the audits arm: the audit self-check provokes
	# breaches on purpose (a window), which an armed audit would rightly report.
	scriptfail=0
	"$repo/scripts/lib/sandbox-selfcheck.sh" || scriptfail=1
	"$repo/scripts/lab/fetch.sh" --self-check || scriptfail=1
	"$repo/scripts/lab/guests/alpine/build.sh" --self-check || scriptfail=1
	"$repo/scripts/lab/audit/selfcheck.sh" || scriptfail=1
	((scriptfail)) && echo "lab: a script self-check FAILED"
	lab_run harness 1 "$scriptfail"
	;;
run) lab_run "$(lab_tiers)" ;;
*)
	echo "lab.sh: --$mode isn't available yet" >&2
	exit 64
	;;
esac
