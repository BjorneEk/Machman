//
//  SettledTests.swift
//  MachmanDesktopCoreTests
//
//  Q34: negative checks ("nothing was sent") waited a fixed 50–600 ms, which proves nothing
//  on a loaded machine. settled() waits until the work an action set off has run out; these
//  are its own checks — it sees work that leaves the main actor and comes back, and it says
//  so when the work never settles.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// Leaves the main actor for the global executor, as a call through a nonisolated
// requirement does.
private func hopOffTheMainActor() async {}

// L1: the test helper itself.
@MainActor
struct SettledTests {
	@Test("Q34: settled() sees a call issued from a Task that hops off the main actor")
	func settledSeesWorkThatHopsOffMain() async {
		var sent = 0
		Task {
			for _ in 0..<3 { await hopOffTheMainActor() }
			sent += 1
		}
		#expect(await settled { sent })
		#expect(sent == 1)
	}

	@Test("Q34: settled() reports false while the snapshot keeps changing")
	func settledSaysWhenWorkNeverStops() async {
		var ticks = 0
		let quiet = await settled(timeout: .milliseconds(200)) {
			ticks += 1
			return ticks
		}
		#expect(!quiet)
	}

	// The harness's own snapshot: a refused start's alert lands before settled() returns.
	@Test("Q34: the harness settles after an action's call and its alert")
	func theHarnessSettlesAfterTheAlert() async {
		let h = await DesktopHarness.make()
		h.stub.fail("start", with: MachmanError(code: .invalidState, message: "no"))
		h.viewModel.startVM("Alpine")
		#expect(await h.settled())
		#expect(h.stub.calls.contains("start"))
		#expect(h.viewModel.presentedError?.message == "no")
	}
}
