//
//  RoutingStartStallTests.swift
//  MachmanCoreTests
//
//  E64: a start awaited its vmhost's answer to the forwarded boot for up to the slow class's
//  hour, listing the VM as starting and never probing it, while vm.stop and vm.process.end
//  refused it as starting — the way out was quitting the agent. A start's vmhost stays
//  reachable now (K14): Force Stop and End Process end it and the start fails as canceled,
//  and one that stops answering lists Not responding. The spawn runs through the launch seam
//  (RoutingSpawnTests); the stub vmhost parks its start (StubMachman.stalled).
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct RoutingStartStallTests {
	private struct Stalled {
		let routing: RoutingMachman
		let stub: StubMachman
		let server: MachmanServer
		let app: StandInVMHostApp
		let start: Task<Void, Error>
	}

	// alpha's start, spawned and forwarded to a stub vmhost that parks `stalled`.
	@MainActor
	private func stalledStart(
		_ tag: String, stalled: Set<String>, probeDeadline: Duration = .seconds(10),
		clock: TestClock? = nil
	) async throws -> Stalled {
		let rig = try RoutingSpawnTests.makeRig(tag)
		if let clock { rig.routing.clock = clock }
		rig.routing.hostProbeDeadline = probeDeadline
		rig.routing.recoveryInterval = .milliseconds(200)
		let (stub, server) = try RoutingSpawnTests.stubHost(rig.socketPath)
		stub.stalled = stalled
		let app = StandInVMHostApp()
		app.onEnd = { server.stop() }   // its exit: the stub host stops serving
		rig.routing.launchVMHost = { _, _ in
			try startServing(server)
			return app
		}
		rig.routing.isProcessAlive = { _ in false }
		let routing = rig.routing
		let start = Task { @MainActor in
			try await routing.start(vm: "alpha", options: StartOptions(openWindow: false))
		}
		#expect(await eventually { stub.calls.contains("start") })
		return Stalled(routing: routing, stub: stub, server: server, app: app, start: start)
	}

	@MainActor
	private func expectCanceled(_ start: Task<Void, Error>) async {
		switch await start.result {
		case .success:
			Issue.record("the start went through after its vmhost was ended")
		case .failure(let error):
			let failure = error as? MachmanError
			#expect(failure?.code == .cancelled)
			#expect(failure?.message == "The start was canceled")
		}
	}

	@Test(
		"""
		E64: a Force Stop during a start whose vmhost never answers ends it, and the start \
		fails as canceled
		""")
	@MainActor func aForceStopEndsAStalledStart() async throws {
		let stalled = try await stalledStart("stall-stop", stalled: ["start"])
		defer {
			stalled.stub.stalled = []
			stalled.server.stop()
		}
		// Before: "alpha is starting — try again once it is running".
		try await stalled.routing.stop(vm: "alpha", mode: .force)
		#expect(stalled.app.ended == 1)
		await expectCanceled(stalled.start)
		#expect(stalled.routing.pendingStarts.isEmpty)
		#expect(stalled.routing.hostedNames.isEmpty)
		#expect(try await stalled.routing.vm(named: "alpha").state == .stopped)
	}

	// Q40: this listed the VM in a 20 s wall-clock loop until it read not responding. On a
	// TestClock the starting watch's ask is armed at the probe deadline, and one advance past
	// it lists the VM Not responding.
	@Test("E64: a start whose vmhost stops answering lists Not responding, and End Process ends it")
	@MainActor func aStalledStartListsNotRespondingAndEndProcessEndsIt() async throws {
		let clock = TestClock()
		let stalled = try await stalledStart(
			"stall-end", stalled: ["start", "vm"], probeDeadline: .seconds(2), clock: clock)
		defer {
			stalled.stub.stalled = []
			stalled.server.stop()
		}
		// Armed besides it: the forwarded start's own (slow-class) deadline.
		#expect(await eventually { clock.armed.contains(.seconds(2)) })
		clock.advance(by: .seconds(2))
		#expect(await eventually {
			stalled.routing.startsInFlight["alpha"]?.host?.unresponsive == true
		})
		let listed = try await stalled.routing.vm(named: "alpha")
		#expect(listed.state == .starting)
		#expect(listed.isUnresponsive)

		// Before: "alpha is starting — try again once it is running". Its reply waits for the
		// start to end; the wait looks again on the clock.
		let ending = Task { @MainActor in try await stalled.routing.endProcess(vm: "alpha") }
		await expectCanceled(stalled.start)
		clock.advance(by: .milliseconds(50))
		try await ending.value
		#expect(stalled.app.ended == 1)
		#expect(stalled.routing.pendingStarts.isEmpty)
	}
}
