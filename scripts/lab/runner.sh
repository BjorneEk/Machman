# The lab's test runner: how scripts/lab.sh runs MachmanLabTests, one swift test process
# for a serial run, or a parallel run's plan and its shard workers, with progress.py
# following either. Sourced by lab.sh after scripts/lib/sandbox.sh, never executed; its
# functions share lab.sh's globals (root, jobs, filter, SHARD_ROOTS, …) and lab_run's locals
# (teststatus, ts, filt).

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

# lab_worker <shard> <queue>: the shard's tests, one suite per swift test process, from <queue>
# until it is empty; each suite's shard, exit status and seconds go to report/suite-runs.tsv.
# --ignore-lock: SwiftPM locks .build for every swift test, building or not, which would run
# the shards one at a time; nothing builds while they run (--skip-build).
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
			sandbox_awake swift test --skip-build --ignore-lock --disable-xctest --no-parallel \
				--package-path "$pkg" --filter "$f" \
				--event-stream-output-path "$r/report/events/$s.jsonl" --event-stream-version 0
		) >> "$r/report/swift-test.log" 2>&1
		st=$?
		printf '%s\t%s\t%s\t%s\n' "$s" "$k" "$st" "$((SECONDS - t0))" \
			>> "$root/report/suite-runs.tsv"
	done
	return 0
}

# lab_progress_ok: swift test writes Swift Testing's event stream and python3 is a real one
# (not the Command Line Tools shim): the live progress follower can run.
lab_progress_ok() {
	command -v python3 >/dev/null 2>&1 || return 1
	[[ "$(command -v python3)" == /usr/bin/python3 ]] && ! xcode-select -p >/dev/null 2>&1 &&
		return 1
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
		MACHMAN_LAB_RUN="$root" swift test list --skip-build --disable-xctest \
		--package-path "$pkg" > "$plan/list.txt" 2> "$plan/list.err"; then
		echo "lab: one shard (swift test list failed: $(tail -n 1 "$plan/list.err"))"
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
			echo "lab: $s's swift test exited $st — see $r/report/swift-test.log"
		done
	python3 "$repo/scripts/lab/plan.py" --record "$root/report/suite-runs.tsv" \
		--history "$history" || true
}

# lab_run_serial: a serial run's test phase: one swift test process for every test the filter
# keeps, progress.py following its event stream. Sets teststatus.
lab_run_serial() {
	local events=()
	if lab_progress_ok; then
		events=(--event-stream-output-path "$root/report/events.jsonl"
			--event-stream-version 0)
		: > "$root/report/events.jsonl"
		python3 "$repo/scripts/lab/progress.py" --run "$root" --level "$verbose" \
			${plain[@]+"${plain[@]}"} --stop "$root/report/progress.stop" &
		FOLLOWPID=$!
	else
		echo "lab: no live progress (python3 or swift test's event stream missing)"
	fi
	{
		set +e
		sandbox_awake swift test --skip-build --disable-xctest --no-parallel \
			--package-path "$pkg" --filter "$filt" ${events[@]+"${events[@]}"} 2>&1
		echo $? > "$root/report/test-status"
	} > "$root/report/swift-test.log" &
	wait $!
	ts="$(cat "$root/report/test-status" 2>/dev/null || echo 1)"
	((ts != 0)) && teststatus=1
	lab_stop_follower
	# No follower, or a test process that never summarized (a crash): swift test's words.
	if ((${#events[@]} == 0)); then
		cat "$root/report/swift-test.log"
	elif ((LAB_FOLLOWSTATUS != 0)); then
		echo "lab: the last of swift test's output ($root/report/swift-test.log):"
		tail -n 40 "$root/report/swift-test.log"
	fi
}
