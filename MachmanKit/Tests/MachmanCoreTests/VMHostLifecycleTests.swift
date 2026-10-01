//
//  VMHostLifecycleTests.swift
//  MachmanTests
//
//  When a vmhost exits on its own (E12): the idle backstop never kills a start the daemon
//  forwarded at its deadline, and a stop's flush never ends a run that began inside it.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanCore

@MainActor
struct VMHostLifecycleTests {
	@Test func theIdleBackstopSparesAStartInFlight() {
		let lifecycle = VMHostLifecycle()
		#expect(lifecycle.idleExitDue(startInFlight: false))    // no start ever came
		#expect(!lifecycle.idleExitDue(startInFlight: true))    // one is booting right now
		lifecycle.hadRunning = true
		#expect(!lifecycle.idleExitDue(startInFlight: false))   // the stop watcher owns it
	}

	@Test func aStopsFlushSparesARunThatBeganInIt() {
		let lifecycle = VMHostLifecycle()
		#expect(!lifecycle.stopExitDue(running: false))   // never ran: not a stop exit
		lifecycle.hadRunning = true
		#expect(lifecycle.stopExitDue(running: false))
		#expect(!lifecycle.stopExitDue(running: true))    // a start forwarded in the flush
	}
}
