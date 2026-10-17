//
//  SettledTests.swift
//  MachmanDesktopCoreTests
//
//  Q34: negative checks ("nothing was sent") waited a fixed 50–600 ms, which proves nothing
//  on a loaded machine. settled() waits until the work an action set off has run out; these
//  are its own checks — it sees work that leaves the main actor and comes back, and it says
//  so when the work never settles. Q41: a main thread another test holds for seconds no longer
//  runs out a wait (settled's or eventually's) that had no turn meanwhile.
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

// What a check reads after the main thread was held (Q41).
@MainActor
private final class Progress {
	var steps = 0
}

// Holds the main thread for `seconds` from a job already queued on it, as another test's
// synchronous subprocess does, then takes `steps` turns through the global executor, counting
// each one into `progress`.
@MainActor
private func holdTheMainThread(_ seconds: Double, thenStep steps: Int, into progress: Progress) {
	DispatchQueue.main.async {
		Thread.sleep(forTimeInterval: seconds)
		MainActor.assumeIsolated {
			Task { @MainActor in
				for _ in 0..<steps {
					await hopOffTheMainActor()
					progress.steps += 1
				}
			}
		}
	}
}

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

	// Q41: under full load another test held this process's main thread for seconds, and a
	// wait whose deadline passed meanwhile gave up at its next look, though the work it
	// waited for had not had one turn yet.
	@Test("Q41: eventually outlasts a main thread held past its deadline")
	func eventuallyOutlastsAHeldMainThread() async {
		let progress = Progress()
		holdTheMainThread(0.5, thenStep: 3, into: progress)
		#expect(await eventually(timeout: .milliseconds(100)) { progress.steps == 3 })
	}

	@Test("Q41: settled outlasts a main thread held past its deadline")
	func settledOutlastsAHeldMainThread() async {
		let progress = Progress()
		holdTheMainThread(0.5, thenStep: 3, into: progress)
		#expect(await settled(timeout: .milliseconds(100)) { progress.steps })
		#expect(progress.steps == 3)
	}
}
