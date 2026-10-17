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

# lab_runner_find: lab_runner_resolve on this toolchain and package, once the tests are built:
# SwiftPM's testing helper beside swift, the bundle in the bin dir SwiftPM names (asked here,
# before any test process starts), the macOS platform's frameworks (Testing.framework).
lab_runner_find() {
	local swift bin platform
	swift="$(xcrun --find swift 2>/dev/null)" || swift=""
	bin="$(swift build --show-bin-path --package-path "$pkg" 2>/dev/null)" || bin=""
	platform="$(xcrun --show-sdk-platform-path 2>/dev/null)" || platform=""
	lab_runner_resolve "${swift%/*}/../libexec/swift/pm/swiftpm-testing-helper" \
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
# matched the filter, else the process died.
lab_test() {
	local args=() pid st lib="$LAB_TEST_PLATFORM/Library"
	if [[ "$1" == --list ]]; then
		args=(--list-tests)
	else
		args=(--no-parallel --filter "$2")
		[[ -n "$1" ]] && args+=(--event-stream-output-path "$1" --event-stream-version 0)
	fi
	if [[ -z "$LAB_TEST_HELPER" ]]; then
		if [[ "$1" == --list ]]; then
			swift test list --skip-build --disable-xctest --package-path "$pkg"
		else
			sandbox_awake swift test --skip-build --disable-xctest --package-path "$pkg" \
				"${args[@]}"
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
# <queue> until it is empty; each suite's shard, exit status and seconds go to
# report/suite-runs.tsv.
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
		) >> "$r/report/swift-test.log" 2>&1
		st=$?
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

# lab_plan: a parallel run's plan (report/plan/): the lab's tests listed in the first shard's
# sandbox (the test guard wants one), the suites the filter keeps shared out longest first by
# plan.py, the exclusive ones apart; jobs drops to the number of shared suites (1: serial).
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
		--exclusive "$repo/scripts/lab/exclusive-suites.txt" --out "$plan"
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
	local follow=(--run "$root" --planned "$(cat "$plan/planned")" --level "$verbose")
	for r in "$root" ${SHARD_ROOTS[@]+"${SHARD_ROOTS[@]}"}; do mkdir -p "$r/report/events"; done
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
	# A suite whose process died (not exit 0 or 1): where its words are.
	awk -F '\t' '$3 > 1 { print $1, $2, $3 }' "$root/report/suite-runs.tsv" |
		while read -r s k st; do
			r="$root"
			((k > 0)) && r="${SHARD_ROOTS[$((k - 1))]}"
			echo "lab: $s's test process exited $st — see $r/report/swift-test.log"
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
# swift test --ignore-lock lost about one in three to SwiftPM's locked build database), and a
# toolchain without the testing helper runs swift test instead. Prints "ok   <check>" or
# "FAIL <check>: <why>"; returns the failure count.
lab_selfcheck_runner() {
	local failures=0 sc k t lost="" check why
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
	rm -rf "$sc"
	return "$failures"
}
