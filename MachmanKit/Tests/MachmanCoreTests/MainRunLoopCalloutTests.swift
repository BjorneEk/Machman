//
//  MainRunLoopCalloutTests.swift
//  MachmanTests
//
//  O-6c, R3-1: a modal loop (what NSAlert.runModal spins) started through MainRunLoopCallout
//  lets other main-actor jobs run while it spins, so the daemon's and a vmhost's servers keep
//  answering under an alert. The same loop spun straight from a main-actor job holds them
//  until it returns (probed in this runner: it did, for the whole spin).
//

import Testing
import Foundation
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
			return Self.spinNested(until: other, seconds: 15)
		}
		#expect(ranUnderTheLoop)
	}

	@Test func theCalloutHandsItsResultBack() async {
		#expect(await MainRunLoopCallout.run { 42 } == 42)
	}
}
