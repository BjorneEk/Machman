//
//  SoftStopEscalationTests.swift
//  MachmanTests
//
//  V5: the one shutdown follow-up per VM (SoftStopEscalation.swift). The grace period is
//  a GraceGate the test opens, or passes at once; each wait ends by awaiting the follow-up's
//  own task, so nothing here races a clock.
//

import Testing
import Foundation
@testable import MachmanCore

@MainActor
struct SoftStopEscalationTests {
	// A follow-up whose wiring is recorded: every VM runs, and asking answers `force`.
	@MainActor
	private final class Recorder {
		let followUp = SoftStopEscalation()
		var running = true
		var force = true
		var asked: [String] = []
		var forced: [String] = []

		init(gate: GraceGate? = nil) {
			followUp.sleep = { _ in await gate?.wait() }
			followUp.isRunning = { [unowned self] _ in self.running }
			followUp.askToForce = { [unowned self] name in
				self.asked.append(name)
				return self.force
			}
			followUp.force = { [unowned self] in self.forced.append($0) }
		}
	}

	@Test func aGuestThatIgnoresShutDownIsOfferedForce() async throws {
		let r = Recorder()
		let task = try #require(r.followUp.schedule("alpha"))
		await task.value
		#expect(r.asked == ["alpha"])
		#expect(r.forced == ["alpha"])
		#expect(!r.followUp.isPending("alpha"))
	}

	@Test func keepWaitingLeavesItRunning() async throws {
		let r = Recorder()
		r.force = false
		try await #require(r.followUp.schedule("alpha")).value
		#expect(r.asked == ["alpha"])
		#expect(r.forced.isEmpty)
	}

	@Test func aGuestThatStoppedInTimeIsNotAsked() async throws {
		let r = Recorder()
		r.running = false
		try await #require(r.followUp.schedule("alpha")).value
		#expect(r.asked.isEmpty)
		#expect(r.forced.isEmpty)
	}

	@Test func oneFollowUpPerVM() async throws {
		let gate = GraceGate()
		let r = Recorder(gate: gate)
		let first = try #require(r.followUp.schedule("alpha"))
		#expect(r.followUp.schedule("alpha") == nil)    // a second Shut Down adds none
		let other = try #require(r.followUp.schedule("beta"))
		await gate.open()
		await first.value
		await other.value
		#expect(r.asked.sorted() == ["alpha", "beta"])
		#expect(r.followUp.schedule("alpha") != nil)    // the next Shut Down follows up again
	}

	@Test func cancelEndsIt() async throws {
		let gate = GraceGate()
		let r = Recorder(gate: gate)
		let task = try #require(r.followUp.schedule("alpha"))
		r.followUp.cancel("alpha")
		#expect(!r.followUp.isPending("alpha"))
		await gate.open()
		await task.value
		#expect(r.asked.isEmpty)
		#expect(r.forced.isEmpty)
	}

	// Save as New VM renames the VM while the follow-up waits.
	@Test func itFollowsARename() async throws {
		let gate = GraceGate()
		let r = Recorder(gate: gate)
		let task = try #require(r.followUp.schedule("alpha"))
		r.followUp.rekey(from: "alpha", to: "kept")
		#expect(r.followUp.isPending("kept"))
		await gate.open()
		await task.value
		#expect(r.asked == ["kept"])
		#expect(r.forced == ["kept"])
	}
}
