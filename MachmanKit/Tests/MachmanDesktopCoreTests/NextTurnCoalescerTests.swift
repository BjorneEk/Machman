//
//  NextTurnCoalescerTests.swift
//  MachmanDesktopCoreTests
//
//  Q32: the menus, the terminal registry's profile follow and the focus watcher each wrote
//  their own "once, on the next main turn" flag. They share NextTurnCoalescer now; its rule
//  is checked here once.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanDesktopCore

// L1: unit.
@MainActor
struct NextTurnCoalescerTests {
	// Runs once everything the main queue already holds has run.
	private func mainQueueTurn() async {
		await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
	}

	@Test("Q32: a burst of asks runs the action once, on the next main turn")
	func aBurstRunsOnceOnTheNextTurn() async {
		var runs = 0
		let coalescer = NextTurnCoalescer { runs += 1 }
		coalescer.schedule()
		coalescer.schedule()
		coalescer.schedule()
		#expect(runs == 0)   // not inside the turn that asked
		await mainQueueTurn()
		#expect(runs == 1)
		// Asked again after it ran: it runs again, once.
		coalescer.schedule()
		coalescer.schedule()
		await mainQueueTurn()
		#expect(runs == 2)
	}
}
