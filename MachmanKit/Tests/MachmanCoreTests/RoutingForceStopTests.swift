//
//  RoutingForceStopTests.swift
//  MachmanTests
//
//  E36: Force Stop on a VM whose vmhost stopped answering was forwarded to that host and
//  failed after 30 s, and the quit path's "Force Stop All" left it running without a word.
//  The forwarded force stop is bounded now; a host that misses it is listed as not
//  responding and the stop answers `timeout`, the clients' cue to offer ending its process
//  (C9: only after a second, explicit confirmation). A stub vmhost "wedges" by parking stop.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct RoutingForceStopTests {
	private struct Rig {
		let routing: RoutingMachman
		let stub: StubMachman
		let server: MachmanServer
	}

	// alpha, running in an adopted stub host. The force stop's bound is short: these tests
	// want it to run out, and it can only expire.
	@MainActor
	private func makeRig() async throws -> Rig {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2).saveVMConfig()
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }   // a test never finds (or launches) a real vmhost
		}
		routing.hostProbeDeadline = .seconds(10)
		routing.forceStopDeadline = .seconds(1)
		let socketPath = TestEnvironment.socketPath("mm-force")
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath)
		routing.adopt(identity: identity, client: try await routing.connectHost(identity: identity))
		return Rig(routing: routing, stub: stub, server: server)
	}

	@MainActor
	private func finish(_ rig: Rig) {
		rig.stub.stalled = []
		rig.server.stop()
	}

	@Test @MainActor func aForceStopTheHostMissesAnswersTimeout() async throws {
		let rig = try await makeRig()
		defer { finish(rig) }
		rig.stub.stalled = ["stop"]

		let clock = ContinuousClock()
		let started = clock.now
		do {
			try await rig.routing.stop(vm: "alpha", mode: .force)
			Issue.record("a wedged host's force stop went through")
		} catch let error as MachmanError {
			#expect(error.code == .timeout)
			#expect(error.message == "alpha isn\u{2019}t answering, so it didn\u{2019}t stop")
		}
		#expect(clock.now - started < .seconds(10))   // before: the call's 30 s
		#expect(rig.routing.hostForTesting("alpha")?.unresponsive == true)
		#expect(rig.routing.hostedNames == ["alpha"])   // listed, never ended here
	}

	// Shut Down asks the guest through the host: one that doesn't answer is refused at once.
	@Test @MainActor func aShutDownOfANotRespondingVMIsRefusedAtOnce() async throws {
		let rig = try await makeRig()
		defer { finish(rig) }
		rig.stub.stalled = ["stop"]
		_ = try? await rig.routing.stop(vm: "alpha", mode: .force)   // marks it
		let asked = rig.stub.calls.filter { $0 == "stop" }.count

		do {
			try await rig.routing.stop(vm: "alpha", mode: .soft)
			Issue.record("a shut down went to a host that doesn't answer")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message == "alpha is not responding \u{2014} use Force Stop")
		}
		#expect(rig.stub.calls.filter { $0 == "stop" }.count == asked)
	}

	// "Force Stop All & Quit" says which VMs it couldn't stop, and doesn't wait on them.
	@Test @MainActor func stopAllNamesTheHostsLeftRunning() async throws {
		let rig = try await makeRig()
		defer { finish(rig) }
		rig.stub.stalled = ["stop"]

		let clock = ContinuousClock()
		let started = clock.now
		let left = await rig.routing.stopAllHosted(softFirst: false, graceSeconds: 0)
		#expect(left == ["alpha"])
		#expect(clock.now - started < .seconds(9))   // not the 10 s drain on top
	}
}
