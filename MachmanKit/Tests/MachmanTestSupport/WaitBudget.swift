//
//  WaitBudget.swift
//  MachmanTestSupport
//
//  A wait's deadline in the time the wait was given (Q41). Under full load another test held
//  the process's main thread for seconds (a synchronous subprocess, a fork, a file sync), and
//  a wait whose wall-clock deadline passed meanwhile gave up at its next look, before the work
//  it waited for had had a single turn. Each look here credits the time since the previous
//  one, but at most one turn — a little over the wait's own pace between looks: a stretch the
//  main thread spent elsewhere counts as one turn. Unloaded, every look is credited in full
//  and the deadline is the wall clock's. A wait still runs out once it has had its turns past
//  the deadline — it only ever waits longer, so it can never turn a real failure into a pass.
//

import Foundation

struct WaitBudget {
	private let clock = ContinuousClock()
	private let timeout: Duration
	private let turn: Duration
	private var credited: Duration = .zero
	private var last: ContinuousClock.Instant

	// `turn`: the most one look is credited (eventually sleeps 10 ms between looks; a settled
	// round is one main-queue turn and one hop, far less).
	init(_ timeout: Duration, turn: Duration) {
		self.timeout = timeout
		self.turn = turn
		last = clock.now
	}

	// Credits the time since the last look; false once the credited time reaches the timeout.
	mutating func lasts() -> Bool {
		let now = clock.now
		credited += min(now - last, turn)
		last = now
		return credited < timeout
	}
}
