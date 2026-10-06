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
# (watch/summary.txt, watch/lab-processes.txt, watch/non-lab-machman.txt, snapshot-summary.txt,
# worktree.txt, swift-test.log).
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
		# shellcheck disable=SC2046
		sandbox_lab_teardown "$root" $( { lab_pidfile_pids "$root"
			sandbox_token_pids "${token:-}"; } | sort -u)
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
		# grep reads to the end: an early -q exit would SIGPIPE strings, which pipefail
		# turns into "no marker" on a big debug dylib.
		[[ -f "$f" ]] && strings -a "$f" 2>/dev/null | grep -F -- "$2" >/dev/null && return 0
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

# lab_worktree_status <repo> <file>: the worktree's status, untracked files included.
lab_worktree_status() {
	git -C "$1" status --porcelain=v1 --untracked-files=all > "$2"
}

# lab_worktree_audit <before> <after> <out>: OK, or a breach with the difference.
lab_worktree_audit() {
	if cmp -s "$1" "$2"; then
		echo "OK worktree" > "$3"
	else
		{
			echo "BREACH worktree the run changed the worktree"
			diff "$1" "$2"
		} > "$3" || true
	fi
}

# lab_count_audits <report dir>: prints each BREACH and WARN line of the audit reports and
# sets LAB_BREACHES and LAB_WARNS.
lab_count_audits() {
	local f line
	LAB_BREACHES=0
	LAB_WARNS=0
	for f in "$1/watch/summary.txt" "$1/snapshot-summary.txt" "$1/worktree.txt"; do
		[[ -f "$f" ]] || continue
		while IFS= read -r line; do
			case "$line" in
			BREACH*) LAB_BREACHES=$((LAB_BREACHES + 1)); echo "lab: audit $line" ;;
			WARN*) LAB_WARNS=$((LAB_WARNS + 1)); echo "lab: audit $line" ;;
			esac
		done < "$f"
	done
}

# lab_run <tiers> <seams-needed 0|1>: build, arm the audits, run the tests, sweep, report.
# In --self-check the products and the slot are skipped (tiers = harness).
lab_run() {
	local tiers="$1" seams=0 xcb filt hw ts breaches=0 warns=0 report inject=()
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
	lab_worktree_status "$repo" "$root/report/git-before.txt"
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
	# lab.sh --self-check's armed pass provokes one breach (harness tier only).
	if [[ -n "${MACHMAN_LAB_SELFCHECK_INJECT:-}" && "$tiers" == harness ]]; then
		inject=(--inject "$MACHMAN_LAB_SELFCHECK_INJECT" --inject-after 2)
	fi
	"$hw" watch --token "$token" --run "$root" --out "$root/report/watch" \
		${inject[@]+"${inject[@]}"} &
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
	# In the background and waited for, so an interrupt reaches the trap at once. The Mac stays
	# awake for it (sandbox_awake): a console wait timed out across a maintenance sleep.
	rm -f "$root/report/test-status"
	{
		set +e
		sandbox_awake swift test --skip-build --disable-xctest --no-parallel \
			--package-path "$pkg" --filter "$filt" 2>&1
		echo $? > "$root/report/test-status"
	} | tee "$root/report/swift-test.log" &
	wait $!
	ts="$(cat "$root/report/test-status" 2>/dev/null || echo 1)"
	((ts != 0)) && teststatus=1
	# Sweep (the audits still watching), then stop the audits and compare.
	# shellcheck disable=SC2046
	sandbox_lab_teardown "$root" $( { lab_pidfile_pids "$root"; sandbox_token_pids "$token"; } |
		sort -u | grep -vxF -e "$WATCHPID" -e "$LOGPID")
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
	lab_worktree_status "$repo" "$root/report/git-after.txt"
	lab_worktree_audit "$root/report/git-before.txt" "$root/report/git-after.txt" \
		"$root/report/worktree.txt"
	report="$root/report"
	lab_count_audits "$report"
	breaches=$LAB_BREACHES
	warns=$LAB_WARNS
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

# lab_doctor: checks only; runs nothing and writes nothing (no build, agent, VM, download
# or slot). One line per check: ok|WARN|MISSING <what>: <detail>; exit 69 on any MISSING.
lab_doctor() {
	local missing=0 tool cache line free qdir t owner state alive=0 dead=0 none=0 d pid
	ok() { echo "ok $1"; }
	warn() { echo "WARN $1"; }
	miss() { echo "MISSING $1"; missing=1; }
	for tool in xcodebuild swift git curl shasum xz gzip cpio strings plutil hdiutil lsappinfo \
		launchctl log; do
		if command -v "$tool" >/dev/null 2>&1; then ok "$tool: $(command -v "$tool")"
		else miss "$tool: not found"; fi
	done
	if xcrun --find swiftc >/dev/null 2>&1; then ok "swiftc: $(xcrun --find swiftc)"
	else miss "swiftc: xcrun can't find it"; fi
	if id -Gn | tr ' ' '\n' | grep -qx admin; then ok "admin: this user can run log stream"
	else miss "admin: log stream needs an admin user"; fi
	if command -v python3 >/dev/null 2>&1 &&
		! { [[ "$(command -v python3)" == /usr/bin/python3 ]] && ! xcode-select -p >/dev/null 2>&1; }
	then ok "python3: $(command -v python3)"
	else miss "python3: missing, or the Command Line Tools shim (it would pop the installer)"; fi
	for tool in qemu-system-aarch64 qemu-img; do
		if command -v "$tool" >/dev/null 2>&1; then ok "$tool: $(command -v "$tool")"
		else miss "$tool: not found (L3 only)"; fi
	done
	if t="$(command -v qemu-system-aarch64)" &&
		[[ -f "$(dirname "$t")/../share/qemu/edk2-aarch64-code.fd" ]]; then
		ok "edk2: $(dirname "$t")/../share/qemu/edk2-aarch64-code.fd"
	else miss "edk2: edk2-aarch64-code.fd not found beside qemu (L3 only)"; fi
	if [[ -x /usr/sbin/sshd ]]; then ok "sshd: /usr/sbin/sshd"
	else miss "sshd: /usr/sbin/sshd missing (L3 only)"; fi
	ok "docker: not required (the lab never starts it)"
	cache="$(sandbox_lab_cache)"
	if [[ -d "$cache" ]]; then ok "cache: $cache ($(du -sh "$cache" 2>/dev/null | cut -f1))"
	else ok "cache: $cache (not created yet)"; fi
	d="$cache"
	while [[ ! -d "$d" && "$d" != / ]]; do d="$(dirname "$d")"; done
	free="$(df -k "$d" | awk 'NR == 2 { print int($4 / 1048576) }')"
	if ((free < 20)); then warn "disk: only $free GB free for the cache (want 20)"
	else ok "disk: $free GB free for the cache"; fi
	free="$(df -k /tmp | awk 'NR == 2 { print int($4 / 1048576) }')"
	if ((free < 10)); then warn "tmp: only $free GB free on /tmp (want 10)"
	else ok "tmp: $free GB free on /tmp"; fi
	while IFS= read -r line; do
		case "$line" in
		MISSING*) warn "fixture ${line#MISSING }" ;;
		BAD*) warn "fixture $line" ;;
		ok*) ok "fixture ${line#ok }" ;;
		esac
	done < <(MACHMAN_LAB_CACHE="$cache" "$repo/scripts/lab/fetch.sh" --verify 2>&1 || true)
	products="$(lab_products_dir 2>/dev/null || true)"
	if [[ -n "$products" && -d "$products/MachmanDesktop.app" ]]; then
		ok "products: $products"
		if lab_seams_present "$products"; then ok "seams: the test-mode markers are in the build"
		else warn "seams: no test-mode markers in the build; agent tiers refuse"; fi
	else
		warn "products: no Debug MachmanDesktop.app for this worktree; agent tiers refuse"
	fi
	slot="$(sandbox_slot_dir "$repo")/lab.1"
	if [[ -d "$slot" ]]; then
		owner="$(cat "$slot/owner" 2>/dev/null)"
		pid="$(cut -d' ' -f1 <<<"$owner" | tr -cd '0-9')"
		if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then ok "slot: held by $owner (alive)"
		else ok "slot: held by $owner (dead; reclaimed on the next run)"; fi
	else ok "slot: free"; fi
	for d in /tmp/mml.* /tmp/mmt.*; do
		[[ -d "$d" ]] || continue
		if [[ -f "$d/.owner" ]]; then
			pid="$(head -n1 "$d/.owner" | tr -cd '0-9')"
			if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then alive=$((alive + 1))
			else dead=$((dead + 1)); fi
		else none=$((none + 1)); fi
	done
	ok "sandboxes: $alive alive, $dead dead, $none without an owner"
	line="$( { ps -axo pid=,comm= | grep -E '/Machman[A-Za-z]*\.app/Contents/MacOS/' || true; } |
		awk '{ print $1 }' | tr '\n' ' ')"
	if [[ -n "${line// /}" ]]; then
		warn "non-lab Machman processes: $line(protected-path changes during a run become" \
			"warnings while they run)"
	else ok "non-lab Machman processes: none"; fi
	if sandbox_path_budget "com.gustaffranzen.Machman.test-abcd"; then
		ok "path budget: a 4-character token fits sun_path with this temp dir"
	else miss "path budget: even a 4-character token overflows sun_path here"; fi
	if [[ -x "$repo/scripts/lab/sshd/sshd.sh" ]]; then
		"$repo/scripts/lab/sshd/sshd.sh" doctor 2>&1 | sed 's/^/  /' || true
	fi
	exit $((missing ? 69 : 0))
}

# lab_selfcheck_audits: lab.sh's own audit plumbing fails on a provoked breach — the worktree
# audit (a change in a scratch repo), the count over the three report files, and one armed
# harness pass with an injected window breach, which must end "1 breaches" with exit 3.
# Prints "ok   <check>" or "FAIL <check>: <why>"; returns the failure count.
lab_selfcheck_audits() {
	local failures=0 sc out rc
	ok() { echo "ok   $1"; }
	fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }
	sc="$(mktemp -d /tmp/mml-selfcheck.XXXXXX)"
	git init -q "$sc/repo"
	lab_worktree_status "$sc/repo" "$sc/before"
	lab_worktree_status "$sc/repo" "$sc/same"
	echo x > "$sc/repo/stray"
	lab_worktree_status "$sc/repo" "$sc/after"
	lab_worktree_audit "$sc/before" "$sc/same" "$sc/quiet.txt"
	lab_worktree_audit "$sc/before" "$sc/after" "$sc/changed.txt"
	if [[ "$(cat "$sc/quiet.txt")" == "OK worktree" ]] &&
		[[ "$(head -n1 "$sc/changed.txt")" == "BREACH worktree"* ]] &&
		grep -qF "?? stray" "$sc/changed.txt"; then
		ok "audit worktree: a file the run adds to the worktree is a breach"
	else
		fail "audit worktree: a file the run adds to the worktree is a breach" \
			"$(cat "$sc/quiet.txt" "$sc/changed.txt")"
	fi
	mkdir -p "$sc/report/watch"
	printf 'BREACH window x\nOK policy\nNOTE frontmost y\n' > "$sc/report/watch/summary.txt"
	printf 'BREACH snapshot added x\nWARN snapshot changed y\n' > "$sc/report/snapshot-summary.txt"
	cp "$sc/changed.txt" "$sc/report/worktree.txt"
	lab_count_audits "$sc/report" > /dev/null
	if [[ "$LAB_BREACHES/$LAB_WARNS" == 3/1 ]]; then
		ok "audit count: every report file's breaches and warnings are counted"
	else
		fail "audit count: every report file's breaches and warnings are counted" \
			"$LAB_BREACHES breaches, $LAB_WARNS warnings"
	fi
	rm -rf "$sc"
	out="$(MACHMAN_LAB_SELFCHECK_INJECT=window "$repo/scripts/lab.sh" --harness --no-build \
		--filter 'LabHarnessTests/tiersParse' 2>&1)"
	rc=$?
	if [[ $rc == 3 ]] && grep -qxF "lab: audits: 1 breaches, 0 warnings" <<<"$out" &&
		grep -q "^lab: audit BREACH window pid -1 .*(injected)" <<<"$out" &&
		grep -qxF "lab: tests passed" <<<"$out"; then
		ok "audit run: an armed pass with one injected breach reports it and exits 3"
	else
		fail "audit run: an armed pass with one injected breach reports it and exits 3" \
			"exit $rc: $(grep '^lab' <<<"$out")"
	fi
	return "$failures"
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
	lab_selfcheck_audits || scriptfail=1
	((scriptfail)) && echo "lab: a script self-check FAILED"
	lab_run harness 1 "$scriptfail"
	;;
run)
	# The self-check's injected pass (lab_selfcheck_audits) needs no products, like --self-check.
	if [[ -n "${MACHMAN_LAB_SELFCHECK_INJECT:-}" && "$(lab_tiers)" == harness ]]; then
		lab_run harness 1
	fi
	lab_run "$(lab_tiers)"
	;;
doctor) lab_doctor ;;
*)
	echo "lab.sh: --$mode isn't available yet" >&2
	exit 64
	;;
esac
