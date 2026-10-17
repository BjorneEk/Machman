# The lab's test runner: how scripts/lab.sh runs MachmanLabTests, one test process for a
# serial run, or a parallel run's plan and its shard workers, with progress.py following
# either. Sourced by lab.sh after scripts/lib/sandbox.sh, never executed; its functions share
# lab.sh's globals (root, jobs, filter, SHARD_ROOTS, …) and lab_run's locals (teststatus, ts,
# filt).

# The test bundle swift build --build-tests makes of the MachmanKit package.
LAB_TEST_PRODUCT=MachmanKitPackageTests
LAB_TEST_HELPER=""
LAB_TEST_BUNDLE=""
LAB_TEST_PLATFORM=""
LAB_TEST_SDK=""
LAB_TEST_SWIFT=""
LAB_RUNNER_WHY=""

# lab_runner_resolve <helper> <bundle> <platform developer dir> <sdk>: what runs the tests.
# Sets LAB_TEST_HELPER, LAB_TEST_BUNDLE, LAB_TEST_PLATFORM and LAB_TEST_SDK when all are there;
# else LAB_TEST_HELPER stays empty (lab_test runs swift test) and LAB_RUNNER_WHY says what is
# missing.
lab_runner_resolve() {
	LAB_TEST_HELPER=""
	LAB_RUNNER_WHY=""
	if [[ ! -x "$1" ]]; then
		LAB_RUNNER_WHY="no swiftpm-testing-helper at $1"
	elif [[ ! -f "$2" ]]; then
		LAB_RUNNER_WHY="no built test bundle at $2"
	elif [[ ! -d "$3/Library/Frameworks" ]]; then
		LAB_RUNNER_WHY="no platform frameworks under $3"
	else
		LAB_TEST_HELPER="$1"
		LAB_TEST_BUNDLE="$2"
		LAB_TEST_PLATFORM="$3"
		LAB_TEST_SDK="$4"
	fi
}

# lab_runner_toolchain <swift on PATH> <developer dir>: the swift that builds the test bundle
# (PATH's; the /usr/bin shim resolved as it resolves, through xcrun) as LAB_TEST_SWIFT. Fails,
# with LAB_RUNNER_WHY, when it isn't the selected Xcode's: its own helper would load that
# Xcode's Testing frameworks into a bundle another toolchain built. Both are compared by their
# real paths (an Xcode linked as /Applications/Xcode.app is common).
lab_runner_toolchain() {
	local swift="$1" dev=""
	LAB_TEST_SWIFT=""
	[[ "$swift" == /usr/bin/swift ]] && swift="$(xcrun --find swift 2>/dev/null)"
	if [[ -z "$swift" ]]; then
		LAB_RUNNER_WHY="no swift on PATH"
		return 1
	fi
	# Its directory's real path (swift itself links to swift-frontend in the same place).
	swift="$(cd "${swift%/*}" 2>/dev/null && pwd -P || echo "${swift%/*}")/${swift##*/}"
	[[ -n "$2" ]] && dev="$(cd "$2" 2>/dev/null && pwd -P || echo "$2")"
	if [[ -z "$dev" || "$swift" != "$dev"/* ]]; then
		LAB_RUNNER_WHY="swift at $swift isn't the selected Xcode's (${2:-none})"
		return 1
	fi
	LAB_TEST_SWIFT="$swift"
}

# lab_runner_find: lab_runner_resolve on this toolchain and package, once the tests are built:
# the testing helper of the toolchain whose swift builds the bundle (lab_runner_toolchain; any
# other → swift test), the bundle in the bin dir SwiftPM names (asked here, before any test
# process starts), the macOS platform's frameworks (Testing.framework).
lab_runner_find() {
	local bin platform
	if ! lab_runner_toolchain "$(command -v swift 2>/dev/null)" "$(xcode-select -p 2>/dev/null)"
	then
		LAB_TEST_HELPER=""
		return 0
	fi
	bin="$(swift build --show-bin-path --package-path "$pkg" 2>/dev/null)" || bin=""
	platform="$(xcrun --show-sdk-platform-path 2>/dev/null)" || platform=""
	lab_runner_resolve "${LAB_TEST_SWIFT%/*}/../libexec/swift/pm/swiftpm-testing-helper" \
		"$bin/$LAB_TEST_PRODUCT.xctest/Contents/MacOS/$LAB_TEST_PRODUCT" "$platform/Developer" \
		"$(xcrun --show-sdk-path 2>/dev/null)"
}

# lab_test <events file or ""> <filter>: the tests the filter keeps, in one test process, its
# output on stdout; lab_test --list: every test's id, a line each. The built bundle runs through
# SwiftPM's testing helper, as swift test runs it, but without SwiftPM, whose build database a
# swift test beside it may hold locked: shards lost whole suites to "unable to attach DB" (Q27).
# Without the helper (lab_runner_resolve), swift test runs it. The helper's environment is set on
# it, not inherited: the system strips DYLD_* from what passes through caffeinate, which keeps
# the Mac awake while it runs (sandbox_awake). Exit status: 0 passed, 1 failed, 69 no test
# matched the filter (swift test's warning for it is read as 69 too), else the process died.
lab_test() {
	local args=() pid st log lib="$LAB_TEST_PLATFORM/Library"
	if [[ "$1" == --list ]]; then
		args=(--list-tests)
	else
		args=(--no-parallel --filter "$2")
		[[ -n "$1" && -z "${MACHMAN_LAB_SELFCHECK_NO_EVENTS:-}" ]] &&
			args+=(--event-stream-output-path "$1" --event-stream-version 0)
	fi
	if [[ -z "$LAB_TEST_HELPER" ]]; then
		if [[ "$1" == --list ]]; then
			swift test list --skip-build --disable-xctest --package-path "$pkg"
		else
			# SwiftPM answers a filter that matched no test with a warning and exit 0.
			log="$(mktemp /tmp/mml-test.XXXXXX)"
			sandbox_awake swift test --skip-build --disable-xctest --package-path "$pkg" \
				"${args[@]}" 2>&1 | tee "$log"
			st=${PIPESTATUS[0]}
			if ((st == 0)) && grep -qF "No matching test cases were run" "$log"; then st=69; fi
			rm -f "$log"
			return "$st"
		fi
		return
	fi
	DYLD_FRAMEWORK_PATH="$lib/Frameworks:$lib/PrivateFrameworks" \
		DYLD_LIBRARY_PATH="$LAB_TEST_PLATFORM/usr/lib" SDKROOT="$LAB_TEST_SDK" NO_COLOR=1 \
		"$LAB_TEST_HELPER" --test-bundle-path "$LAB_TEST_BUNDLE" "${args[@]}" "$LAB_TEST_BUNDLE" \
		--testing-library swift-testing &
	pid=$!
	[[ -x /usr/bin/caffeinate ]] && /usr/bin/caffeinate -i -s -w "$pid" &
	wait "$pid"
	st=$?
	return "$st"
}

# lab_queue_pop <queue>: the queue's first line, removed from it (a mkdir lock between
# workers); fails when the queue is empty.
lab_queue_pop() {
	local q="$1" line
	until mkdir "$q.lock" 2>/dev/null; do sleep 0.05; done
	line="$(head -n 1 "$q")"
	if [[ -n "$line" ]]; then tail -n +2 "$q" > "$q.next" && mv "$q.next" "$q"; fi
	rmdir "$q.lock"
	[[ -n "$line" ]] && printf '%s\n' "$line"
}

# lab_worker <shard> <queue>: the shard's tests, one suite per test process (lab_test), from
# <queue> until it is empty; each suite's output goes to report/runs/<suite>.log and the
# shard's swift-test.log, its shard, exit status and seconds to report/suite-runs.tsv.
lab_worker() {
	set +e
	local k="$1" q="$2" r line s f st t0
	r="$root"
	((k > 0)) && r="${SHARD_ROOTS[$((k - 1))]}"
	while line="$(lab_queue_pop "$q")"; do
		s="${line%%$'\t'*}"
		f="${line#*$'\t'}"
		t0=$SECONDS
		(
			. "$r/shard.env"
			lab_test "$r/report/events/$s.jsonl" "$f"
		) > "$r/report/runs/$s.log" 2>&1
		st=$?
		cat "$r/report/runs/$s.log" >> "$r/report/swift-test.log"
		printf '%s\t%s\t%s\t%s\n' "$s" "$k" "$st" "$((SECONDS - t0))" \
			>> "$root/report/suite-runs.tsv"
	done
	return 0
}

# lab_progress_ok: the test process writes Swift Testing's event stream (the testing helper
# always does; swift test says so in its help) and python3 is a real one (not the Command Line
# Tools shim): the live progress follower can run.
lab_progress_ok() {
	command -v python3 >/dev/null 2>&1 || return 1
	[[ "$(command -v python3)" == /usr/bin/python3 ]] && ! xcode-select -p >/dev/null 2>&1 &&
		return 1
	[[ -n "$LAB_TEST_HELPER" ]] ||
		swift test --help-hidden 2>/dev/null | grep -F -- --event-stream-output-path >/dev/null
}

# lab_stop_follower: lets progress.py drain and print its summary (20 s at most), then stops
# it; LAB_FOLLOWSTATUS is its exit status (2: a test process never summarized).
lab_stop_follower() {
	LAB_FOLLOWSTATUS=0
	[[ -n "$FOLLOWPID" ]] || return 0
	touch "$root/report/progress.stop"
	local waited=0
	while kill -0 "$FOLLOWPID" 2>/dev/null && ((waited < 20)); do
		sleep 0.5
		waited=$((waited + 1))
	done
	kill -TERM "$FOLLOWPID" 2>/dev/null || true
	wait "$FOLLOWPID" 2>/dev/null || LAB_FOLLOWSTATUS=$?
	FOLLOWPID=""
}

# The runner's self-check knobs: each makes a pass misbehave on purpose (lab_selfcheck_runner).
# MACHMAN_LAB_SELFCHECK_NO_EVENTS: lab_test leaves out the event stream, as a helper ignoring
# its path would.
LAB_SELFCHECK_KNOBS=(MACHMAN_LAB_SELFCHECK_EMPTY_SUITE MACHMAN_LAB_SELFCHECK_NO_EVENTS)

# lab_selfcheck_knobs <self-check pass 0|1>: outside a self-check pass (lab_run's, harness tier
# only) every knob is dropped, said once: a leftover export must never fail a real run.
lab_selfcheck_knobs() {
	local knob
	((${1:-0})) && return 0
	for knob in "${LAB_SELFCHECK_KNOBS[@]}"; do
		if [[ -n "${!knob:-}" ]]; then
			echo "lab: ignored $knob (it acts in a self-check pass only)"
			unset "$knob"
		fi
	done
	return 0
}

# lab_plan: a parallel run's plan (report/plan/): the lab's tests listed in the first shard's
# sandbox (the test guard wants one), the suites the filter keeps shared out longest first by
# plan.py, the exclusive ones apart, each placed at its declaration; jobs drops to the number of
# shared suites (1: serial). lab.sh --self-check's injected pass adds a suite whose filter
# matches no test (MACHMAN_LAB_SELFCHECK_EMPTY_SUITE, a knob only a self-check pass keeps).
lab_plan() {
	local plan="$root/report/plan" shared
	mkdir -p "$plan"
	if ! MACHMAN_SUITE_ID="$suite" MACHMAN_DATA_DIR="$root/data" CFFIXED_USER_HOME="$root/home" \
		MACHMAN_LAB_RUN="$root" lab_test --list > "$plan/list.txt" 2> "$plan/list.err"; then
		echo "lab: one shard (listing the tests failed: $(tail -n 1 "$plan/list.err"))"
		jobs=1
		return 0
	fi
	python3 "$repo/scripts/lab/plan.py" --list "$plan/list.txt" ${filter:+--filter "$filter"} \
		--history "$MACHMAN_LAB_CACHE/suite-times.json" \
		--exclusive "$repo/scripts/lab/exclusive-suites.txt" \
		--sources "$pkg/Tests/MachmanLabTests" --out "$plan"
	if [[ -n "${MACHMAN_LAB_SELFCHECK_EMPTY_SUITE:-}" ]]; then
		printf '%s\t%s\n' Q27EmptySuite 'MachmanLabTests\.Q27EmptySuite/' >> "$plan/queue"
		printf '%s\t%s\t%s\n' Q27EmptySuite Q27EmptySuite.swift:1 1 >> "$plan/suites"
	fi
	shared="$(wc -l < "$plan/queue" | tr -d ' ')"
	((shared < jobs)) && jobs=$((shared > 1 ? shared : 1))
	return 0
}

# lab_run_shards: a parallel run's test phase, on lab_plan's plan: one worker per shard runs
# the shared suites a suite at a time; the exclusive ones then run alone on the first shard.
# Sets teststatus; records the suites' times for the next plan.
lab_run_shards() {
	local plan="$root/report/plan" k r history="$MACHMAN_LAB_CACHE/suite-times.json"
	echo "lab: $(wc -l < "$plan/queue" | tr -d ' ') suites shared by $jobs shards," \
		"$(wc -l < "$plan/serial" | tr -d ' ') alone after them"
	: > "$root/report/suite-runs.tsv"
	local follow=(--run "$root" --planned "$(cat "$plan/planned")" --suites "$plan/suites"
		--level "$verbose")
	for r in "$root" ${SHARD_ROOTS[@]+"${SHARD_ROOTS[@]}"}; do
		mkdir -p "$r/report/events" "$r/report/runs"
	done
	for r in ${SHARD_ROOTS[@]+"${SHARD_ROOTS[@]}"}; do follow+=(--shard "$r"); done
	python3 "$repo/scripts/lab/progress.py" "${follow[@]}" ${plain[@]+"${plain[@]}"} \
		--stop "$root/report/progress.stop" &
	FOLLOWPID=$!
	WORKERPIDS=()
	for ((k = 0; k < jobs; k++)); do
		lab_worker "$k" "$plan/queue" &
		WORKERPIDS+=($!)
	done
	for k in "${WORKERPIDS[@]}"; do wait "$k" || true; done
	WORKERPIDS=()
	(lab_worker 0 "$plan/serial")
	ts="$(awk -F '\t' '$3 != 0 { bad++ } END { print bad + 0 }' "$root/report/suite-runs.tsv")"
	((ts != 0)) && teststatus=1
	ts="$ts of $(wc -l < "$root/report/suite-runs.tsv" | tr -d ' ') suites failed"
	lab_stop_follower
	# A planned suite that reported no test (progress.py exits 3) fails the run whatever its
	# process's exit status said.
	if ((LAB_FOLLOWSTATUS == 3)); then
		teststatus=1
		ts="$ts; a planned suite ran no tests"
	fi
	# A suite whose process died (not exit 0 or 1, nor 69: progress.py named a suite that ran
	# no tests): where its words are.
	awk -F '\t' '$3 > 1 && $3 != 69 { print $1, $2, $3 }' "$root/report/suite-runs.tsv" |
		while read -r s k st; do
			r="$root"
			((k > 0)) && r="${SHARD_ROOTS[$((k - 1))]}"
			echo "lab: $s's test process exited $st — see $r/report/runs/$s.log"
		done
	python3 "$repo/scripts/lab/plan.py" --record "$root/report/suite-runs.tsv" \
		--history "$history" || true
}

# lab_run_serial: a serial run's test phase: one test process (lab_test) for every test the
# filter keeps, progress.py following its event stream. Sets teststatus.
lab_run_serial() {
	local events=""
	if lab_progress_ok; then
		events="$root/report/events.jsonl"
		: > "$events"
		python3 "$repo/scripts/lab/progress.py" --run "$root" --level "$verbose" \
			${plain[@]+"${plain[@]}"} --stop "$root/report/progress.stop" &
		FOLLOWPID=$!
	else
		echo "lab: no live progress (python3 or the test process's event stream missing)"
	fi
	{
		set +e
		lab_test "$events" "$filt" 2>&1
		echo $? > "$root/report/test-status"
	} > "$root/report/swift-test.log" &
	wait $!
	ts="$(cat "$root/report/test-status" 2>/dev/null || echo 1)"
	((ts != 0)) && teststatus=1
	lab_stop_follower
	# No follower, or a test process that never summarized (a crash): its own words.
	if [[ -z "$events" ]]; then
		cat "$root/report/swift-test.log"
	elif ((LAB_FOLLOWSTATUS != 0)); then
		echo "lab: the last of the test process's output ($root/report/swift-test.log):"
		tail -n 40 "$root/report/swift-test.log"
	fi
}

# lab_selfcheck_runner: the runner's own checks, on the built test bundle (Q27): eight test
# processes side by side, each in a scratch sandbox of its own, all report their test (eight
# swift test --ignore-lock lost about one in three to SwiftPM's locked build database); a
# toolchain without the testing helper runs swift test instead; and an armed two-shard harness
# pass with a planned suite that runs nothing fails, naming it where failcheck reads it.
# Prints "ok   <check>" or "FAIL <check>: <why>"; returns the failure count.
lab_selfcheck_runner() {
	local failures=0 sc k t lost="" check why out rc
	sc="$(mktemp -d /tmp/mml-selfcheck.XXXXXX)"
	check="Q27: eight runs of the built test bundle side by side each report their test"
	lab_runner_find
	if [[ -z "$LAB_TEST_HELPER" ]]; then
		echo "FAIL $check: $LAB_RUNNER_WHY"
		failures=$((failures + 1))
	else
		for k in 1 2 3 4 5 6 7 8; do
			t="selfq27r$k"
			mkdir -p "$sc/$t/data" "$sc/$t/home"
			(
				export MACHMAN_SUITE_ID="com.gustaffranzen.Machman.test-$t" \
					MACHMAN_DATA_DIR="$sc/$t/data" CFFIXED_USER_HOME="$sc/$t/home"
				lab_test "$sc/$t.jsonl" 'MachmanLabTests\.LabHarnessTests/tiersParse'
			) > "$sc/$t.log" 2>&1 &
		done
		wait
		for k in 1 2 3 4 5 6 7 8; do
			t="selfq27r$k"
			grep -qF '"kind":"runEnded"' "$sc/$t.jsonl" 2>/dev/null &&
				grep -E '"kind":"test(Ended|Skipped)"' "$sc/$t.jsonl" | grep -qF tiersParse ||
				lost="$lost $k ($(grep -m 1 -o 'error: .*' "$sc/$t.log" || tail -n 1 "$sc/$t.log"))"
		done
		if [[ -z "$lost" ]]; then
			echo "ok   $check"
		else
			echo "FAIL $check: lost run$lost"
			failures=$((failures + 1))
		fi
	fi
	check="Q27: a toolchain without the testing helper runs swift test instead"
	why="$(lab_runner_resolve "$sc/none/swiftpm-testing-helper" "$LAB_TEST_BUNDLE" \
		"$LAB_TEST_PLATFORM" "$LAB_TEST_SDK"
		echo "${LAB_TEST_HELPER:-swift test}: $LAB_RUNNER_WHY")"
	if [[ "$why" == "swift test: no swiftpm-testing-helper at $sc/none/"* ]]; then
		echo "ok   $check"
	else
		echo "FAIL $check: $why"
		failures=$((failures + 1))
	fi
	check="Q27: the testing helper is the one in the toolchain that builds the test bundle"
	why="$(lab_runner_toolchain /opt/q27/usr/bin/swift /Applications/Q27.app/Contents/Developer
		echo "$? $LAB_RUNNER_WHY")"
	if [[ -n "$LAB_TEST_HELPER" && -n "$LAB_TEST_SWIFT" &&
		"${LAB_TEST_HELPER%/libexec/swift/pm/swiftpm-testing-helper}" == \
		"${LAB_TEST_SWIFT%/swift}/.." &&
		"$why" == "1 swift at /opt/q27/usr/bin/swift isn't the selected Xcode's"* ]]; then
		echo "ok   $check"
	else
		echo "FAIL $check: helper $LAB_TEST_HELPER, swift ${LAB_TEST_SWIFT:-?}; elsewhere: $why"
		failures=$((failures + 1))
	fi
	check="Q27: a selected Xcode reached through a symlink is still the build toolchain"
	local dev
	dev="$(cd "$(xcode-select -p 2>/dev/null)" 2>/dev/null && pwd -P)"
	ln -s "$dev" "$sc/linked-developer"
	why="$(lab_runner_toolchain "$sc/linked-developer/${LAB_TEST_SWIFT#"$dev"/}" \
		"$sc/linked-developer"
		echo "$? ${LAB_TEST_SWIFT:-}${LAB_RUNNER_WHY:+ / $LAB_RUNNER_WHY}")"
	if [[ -n "$dev" && -n "$LAB_TEST_SWIFT" && "$LAB_TEST_SWIFT" == "$dev"/* &&
		"$why" == "0 $LAB_TEST_SWIFT" ]]; then
		echo "ok   $check"
	else
		echo "FAIL $check: developer dir ${dev:-?}, swift ${LAB_TEST_SWIFT:-?}: $why"
		failures=$((failures + 1))
	fi
	check="Q27: through swift test, a filter that matches no test fails as through the helper"
	t="selfq27f"
	mkdir -p "$sc/$t/data" "$sc/$t/home"
	rc=0
	(
		export MACHMAN_SUITE_ID="com.gustaffranzen.Machman.test-$t" \
			MACHMAN_DATA_DIR="$sc/$t/data" CFFIXED_USER_HOME="$sc/$t/home"
		LAB_TEST_HELPER=""
		lab_test "" 'MachmanLabTests\.NoSuchSuiteQ27/'
	) > "$sc/$t.log" 2>&1 || rc=$?
	if [[ $rc == 69 ]]; then
		echo "ok   $check"
	else
		echo "FAIL $check: exit $rc: $(tail -n 1 "$sc/$t.log")"
		failures=$((failures + 1))
	fi
	rm -rf "$sc"
	check="Q27: a self-check knob left in the environment is dropped outside a self-check pass"
	out="$(export MACHMAN_LAB_SELFCHECK_EMPTY_SUITE=1; lab_selfcheck_knobs 0
		echo "left=${MACHMAN_LAB_SELFCHECK_EMPTY_SUITE:-}")"
	why="$(export MACHMAN_LAB_SELFCHECK_EMPTY_SUITE=1; lab_selfcheck_knobs 1
		echo "left=${MACHMAN_LAB_SELFCHECK_EMPTY_SUITE:-}")"
	local said="lab: ignored MACHMAN_LAB_SELFCHECK_EMPTY_SUITE (it acts in a self-check pass only)"
	if [[ "$out" == "$said"$'\n'"left=" && "$why" == "left=1" ]]; then
		echo "ok   $check"
	else
		echo "FAIL $check: outside: $out; inside: $why"
		failures=$((failures + 1))
	fi
	check="Q27: a parallel run with a planned suite that runs nothing fails and names it"
	out="$(MACHMAN_LAB_SELFCHECK_EMPTY_SUITE=1 "$repo/scripts/lab.sh" --harness --no-build \
		--plain --jobs 2 --filter 'LabHarnessTests/tiersParse' 2>&1)"
	rc=$?
	local failed="lab: tests FAILED (1 of 2 suites failed; a planned suite ran no tests)"
	if [[ $rc == 1 ]] && grep -qxF "$failed" <<<"$out" &&
		grep -q "✘ Q27EmptySuite.swift:1: Q27EmptySuite ran no tests — test exit 69" <<<"$out" &&
		grep -q "Test run with 1 test in 1 suite failed" <<<"$out" &&
		grep -qxF "lab: audits: 0 breaches, 0 warnings" <<<"$out"; then
		echo "ok   $check"
	else
		echo "FAIL $check: exit $rc: $(grep -E '^lab|✘|Test run' <<<"$out" | tr '\n' ' ')"
		failures=$((failures + 1))
	fi
	check="Q27: a parallel run whose suites exit 0 but report nothing fails"
	out="$(MACHMAN_LAB_SELFCHECK_NO_EVENTS=1 "$repo/scripts/lab.sh" --harness --no-build \
		--plain --jobs 2 \
		--filter 'LabHarnessTests/tiersParse|LabStartFailureTests/onlyEngineFailures' 2>&1)"
	rc=$?
	failed="lab: tests FAILED (0 of 2 suites failed; a planned suite ran no tests)"
	if [[ $rc == 1 ]] && grep -qxF "$failed" <<<"$out" &&
		grep -q "LabHarnessTests ran no tests — test exit 0" <<<"$out" &&
		grep -qxF "lab: audits: 0 breaches, 0 warnings" <<<"$out"; then
		echo "ok   $check"
	else
		echo "FAIL $check: exit $rc: $(grep -E '^lab|✘|Test run' <<<"$out" | tr '\n' ' ')"
		failures=$((failures + 1))
	fi
	return "$failures"
}
