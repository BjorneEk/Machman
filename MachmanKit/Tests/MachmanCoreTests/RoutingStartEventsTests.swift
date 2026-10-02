//
//  RoutingStartEventsTests.swift
//  MachmanCoreTests
//
//  E9: whatever a vmhost emits while its VM boots — the "started without its uart ports" and
//  "started headless" warnings, its own state changes — reaches the daemon's subscribers. The
//  daemon used to subscribe to a host's events only after the forwarded start returned, so a
//  boot's events went to a bus nobody listened on.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct RoutingStartEventsTests {
	@MainActor
	private func makeRouting() throws -> (RoutingMachman, String) {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			let cfg = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			try cfg.saveVMConfig()
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }
		}
		let socketPath = TestEnvironment.scratch
			+ "mm-boot-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		routing.socketPathForVM = { _ in socketPath }
		routing.helloDeadline = .seconds(10)
		routing.hostProbeDeadline = .seconds(10)
		return (routing, socketPath)
	}

	@Test @MainActor func eventsAVMHostEmitsWhileBootingReachTheDaemonsSubscribers() async throws {
		let (routing, socketPath) = try makeRouting()
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha")   // stopped: the start is forwarded
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let collected = EventLog()
		let stream = await routing.events()
		let reader = Task { @MainActor in
			for await event in stream { collected.append(event) }
		}
		defer { reader.cancel() }

		#expect(try await routing.probeAdoptAndStart(
			name: "alpha", socketPath: socketPath, options: StartOptions(openWindow: false)))
		// The stub emits stateChanged(running) INSIDE its start — a boot-time event.
		#expect(await eventually(timeout: .seconds(10)) {
			collected.events.contains(.stateChanged(vm: "alpha", state: .running))
		})
	}
}

@MainActor
private final class EventLog {
	private(set) var events: [VMEvent] = []
	func append(_ event: VMEvent) { events.append(event) }
}
