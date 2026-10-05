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
import MachmanAPI
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

	// E34: an import proxied to an idle host died at its 180 s backstop.
	@Test func theIdleBackstopSparesAnOperation() {
		let lifecycle = VMHostLifecycle()
		#expect(!lifecycle.idleExitDue(startInFlight: false, operationsRunning: true))
		#expect(lifecycle.idleExitDue(startInFlight: false, operationsRunning: false))
	}

	// E34: a guest that shut down mid-import ended its vmhost 300 ms later, the copy with it.
	// The stop's exit now waits for the host's operations, bounded.
	@Test func aStopsExitWaitsForRunningOperations() async {
		let lifecycle = VMHostLifecycle()
		var polls = 0
		let drained = await lifecycle.drain(
			operationsRunning: { polls < 3 }, limit: .seconds(60),
			sleep: { _ in polls += 1 })
		#expect(drained)
		#expect(polls == 3)

		polls = 0
		let gaveUp = await lifecycle.drain(
			operationsRunning: { true }, limit: .seconds(5), sleep: { _ in polls += 1 })
		#expect(!gaveUp)
		#expect(polls == 5)
	}

	@Test func anOperationCenterSaysWhetherAnythingRuns() {
		let center = OperationCenter(events: EventBus())
		#expect(!center.hasRunning)
		let id = center.begin(kind: OperationInfo.Kind.importDisk, vm: "alpha", label: "x")
		#expect(center.hasRunning)
		center.finish(id, state: OperationInfo.State.succeeded)
		#expect(!center.hasRunning)   // a finished card lingers, but runs no more
	}

	@Test func aStopsFlushSparesARunThatBeganInIt() {
		let lifecycle = VMHostLifecycle()
		#expect(!lifecycle.stopExitDue(running: false))   // never ran: not a stop exit
		lifecycle.hadRunning = true
		#expect(lifecycle.stopExitDue(running: false))
		#expect(!lifecycle.stopExitDue(running: true))    // a start forwarded in the flush
	}
}
