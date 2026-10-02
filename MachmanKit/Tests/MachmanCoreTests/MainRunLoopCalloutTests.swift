//
//  MainRunLoopCalloutTests.swift
//  MachmanTests
//
//  O-6c, R3-1: a modal loop (what NSAlert.runModal spins) started through MainRunLoopCallout
//  lets other main-actor jobs run while it spins, so the daemon's and a vmhost's servers keep
//  answering under an alert. The same loop spun straight from a main-actor job holds them
//  until it returns (probed in this runner: it did, for the whole spin) — and so does one a
//  callout runs inside, when the callout fires in a loop a main-actor job spins (a
//  synchronous Process wait), so the callout waits for that job instead.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanCore

@MainActor
struct MainRunLoopCalloutTests {
	@MainActor
	private final class Flag {
		var isSet = false
	}

	// A modal loop's stand-in: the main run loop, nested, until `flag` is set or time is up.
	private static func spinNested(until flag: Flag, seconds: Double) -> Bool {
		let end = Date().addingTimeInterval(seconds)
		while Date() < end, !flag.isSet {
			_ = CFRunLoopRunInMode(.defaultMode, 0.05, false)
		}
		return flag.isSet
	}

	@Test func otherMainActorJobsRunUnderALoopStartedFromTheCallout() async {
		let ranUnderTheLoop = await MainRunLoopCallout.run { () -> Bool in
			let other = Flag()
			Task { @MainActor in other.isSet = true }   // e.g. the server handling a request
			return Self.spinNested(until: other, seconds: 10)
		}
		#expect(ranUnderTheLoop)
	}

	@Test func theCalloutHandsItsResultBack() async {
		#expect(await MainRunLoopCallout.run { 42 } == 42)
	}

	// What ssh-keygen's waitUntilExit on the main actor does: this job spins the run loop
	// while the work is due. The work must not run in there, but once the job has ended.
	@Test func workDueInsideAMainActorJobsLoopWaitsForTheJob() async {
		let inTheJob = Flag()
		let ranInTheJob = Flag()
		let done = Flag()
		inTheJob.isSet = true
		MainRunLoopCallout.post {
			ranInTheJob.isSet = inTheJob.isSet
			done.isSet = true
		}
		_ = Self.spinNested(until: done, seconds: 0.5)   // expires unless the work runs here
		inTheJob.isSet = false
		#expect(await eventually { done.isSet })
		#expect(!ranInTheJob.isSet)
	}
}
