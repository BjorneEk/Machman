//
//  Settled.swift
//  MachmanTestSupport
//
//  For a negative check — nothing was sent, no alert came — wait until the work an action
//  set off has run out, instead of sleeping a fixed time (Q34): a short sleep lets a late
//  send pass on a loaded machine, and a long one only slows every run. settled() runs rounds
//  of one main-queue turn and one hop through the global executor and back (where a call to
//  a main-actor object from a nonisolated requirement passes) until `snapshot` has held still
//  for `quietRounds` rounds in a row. Work a timer schedules — a retry's back-off, a toast's
//  lifetime, the alert queue's represent delay — is not waited for: a check about that waits
//  for its own outcome (eventually).
//

import Foundation

// True once `snapshot` held still for `quietRounds` rounds; false if it was still changing
// at `timeout` (the work never settled), so the call site's #expect reports it.
@MainActor
public func settled<Snapshot: Equatable>(
	quietRounds: Int = 10, timeout: Duration = .seconds(10),
	_ snapshot: @MainActor () -> Snapshot
) async -> Bool {
	let clock = ContinuousClock()
	let deadline = clock.now.advanced(by: timeout)
	var last = snapshot()
	var quiet = 0
	while quiet < quietRounds {
		guard clock.now < deadline else { return false }
		await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
		await Task.detached {}.value
		let now = snapshot()
		if now == last {
			quiet += 1
		} else {
			last = now
			quiet = 0
		}
	}
	return true
}
