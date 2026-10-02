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

	// The question no longer holds the main actor (R3-1), so the guest can finish shutting
	// down while it shows: a Force Stop answer then has nothing left to stop.
	@Test func aGuestThatStopsWhileAskedIsNotForced() async throws {
		let r = Recorder()
		r.followUp.askToForce = { [unowned r] name in
			r.asked.append(name)
			r.running = false
			return true
		}
		try await #require(r.followUp.schedule("alpha")).value
		#expect(r.asked == ["alpha"])
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

	// The question no longer holds the main actor (R3-1), so Save as New VM can rename the VM
	// while it shows (RR3-2): a Force Stop answer then stops the VM under its new name.
	@Test func aRenameWhileAskedIsFollowed() async throws {
		let r = Recorder()
		var current = "alpha"
		r.followUp.isRunning = { $0 == current }
		r.followUp.askToForce = { [unowned r] name in
			r.asked.append(name)
			r.followUp.rekey(from: name, to: "kept")
			current = "kept"
			return true
		}
		try await #require(r.followUp.schedule("alpha")).value
		#expect(r.asked == ["alpha"])
		#expect(r.forced == ["kept"])
		#expect(!r.followUp.isPending("kept"))
	}

	// While the question shows, the follow-up is still the VM's one: a second Shut Down adds
	// none (RR3-2).
	@Test func aShutDownWhileAskedAddsNoSecondFollowUp() async throws {
		let r = Recorder()
		var secondAdded: Bool?
		r.followUp.askToForce = { [unowned r] name in
			r.asked.append(name)
			secondAdded = r.followUp.schedule(name) != nil
			return false
		}
		try await #require(r.followUp.schedule("alpha")).value
		#expect(r.asked == ["alpha"])
		#expect(secondAdded == false)
		#expect(!r.followUp.isPending("alpha"))
	}
}
