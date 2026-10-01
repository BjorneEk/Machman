//
//  RoutingUnresponsiveTests.swift
//  MachmanTests
//
//  E20: one stalled vmhost must not hold vm.list, vm.get or host.operations for every client.
//  The router asks all hosts at once, each bounded by a short deadline, and serves a stalled
//  host's VM from its last answer marked unresponsive (never "stopped"); a recovery watcher
//  clears the mark and announces it with listChanged. Two in-process stub hosts adopted over
//  real sockets; a host "stalls" by parking the scripted calls (StubMachman.stalled).
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

@MainActor
private final class EventLog {
	var events: [VMEvent] = []
}

struct RoutingUnresponsiveTests {
	private struct Rig {
		let routing: RoutingMachman
		let alpha: StubMachman
		let beta: StubMachman
		let servers: [MachmanServer]
	}

	// alpha and beta, both running in their own adopted stub host.
	@MainActor
	private func makeRig(deadline: Duration = .milliseconds(300)) async throws -> Rig {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in ["alpha", "beta"] {
				try VMConfig.createNewVMDirectory(name: name)
				let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
				try cfg.saveVMConfig()
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }   // a test never finds (or launches) a real vmhost
		}
		routing.hostProbeDeadline = deadline
		routing.recoveryInterval = .milliseconds(100)
		var stubs: [StubMachman] = []
		var servers: [MachmanServer] = []
		for name in ["alpha", "beta"] {
			let stub = StubMachman()
			stub.vms[name] = StubMachman.makeInfo(name, state: .running)
			let socketPath = TestEnvironment.scratch
				+ "mm-stall-\(name)-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
			let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
			try server.start()
			let identity = RoutingMachman.HostIdentity(
				id: UUID(), name: name, socketPath: socketPath)
			routing.adopt(identity: identity, client: try await routing.connectHost(identity: identity))
			stubs.append(stub)
			servers.append(server)
		}
		return Rig(routing: routing, alpha: stubs[0], beta: stubs[1], servers: servers)
	}

	// Lets parked requests finish, then takes the hosts down.
	@MainActor
	private func finish(_ rig: Rig) {
		rig.alpha.stalled = []
		rig.beta.stalled = []
		for server in rig.servers { server.stop() }
	}

	@Test @MainActor func aStalledHostIsListedFromItsLastAnswer() async throws {
		let rig = try await makeRig()
		defer { finish(rig) }
		_ = try await rig.routing.listVMs()   // alpha answers once: its last answer
		rig.alpha.stalled = ["vm"]

		let clock = ContinuousClock()
		let started = clock.now
		let list = try await rig.routing.listVMs()
		#expect(clock.now - started < .seconds(2))   // before: the 30 s call deadline
		let alpha = list.first { $0.name == "alpha" }
		let beta = list.first { $0.name == "beta" }
		#expect(alpha?.unresponsive == true)
		#expect(alpha?.state == .running)             // never "stopped"
		#expect(beta?.unresponsive == nil)
		#expect(beta?.state == .running)
	}

	@Test @MainActor func aHostThatNeverAnsweredListsAsUnknown() async throws {
		let rig = try await makeRig()
		defer { finish(rig) }
		rig.alpha.stalled = ["vm"]

		let alpha = try await rig.routing.listVMs().first { $0.name == "alpha" }
		#expect(alpha?.unresponsive == true)
		#expect(alpha?.state == .unknown)
	}

	// Asked at once, two stalled hosts cost the list one deadline, not one each.
	@Test @MainActor func twoStalledHostsCostOneDeadline() async throws {
		let rig = try await makeRig(deadline: .seconds(1))
		defer { finish(rig) }
		rig.alpha.stalled = ["vm"]
		rig.beta.stalled = ["vm"]

		let clock = ContinuousClock()
		let started = clock.now
		let list = try await rig.routing.listVMs()
		#expect(clock.now - started < .milliseconds(1800))
		#expect(list.allSatisfy { $0.unresponsive == true })
	}

	@Test @MainActor func recoveryClearsTheMarkAndAnnouncesIt() async throws {
		let rig = try await makeRig()
		defer { finish(rig) }
		rig.alpha.stalled = ["vm"]
		#expect(try await rig.routing.listVMs().first { $0.name == "alpha" }?.unresponsive == true)

		let log = EventLog()
		let stream = await rig.routing.events()
		let pump = Task { @MainActor in
			for await event in stream { log.events.append(event) }
		}
		defer { pump.cancel() }
		rig.alpha.stalled = []
		#expect(await eventually {
			log.events.contains(.listChanged)
				&& rig.routing.hostForTesting("alpha")?.unresponsive == false
		})
		let alpha = try await rig.routing.listVMs().first { $0.name == "alpha" }
		#expect(alpha?.unresponsive == nil)
		#expect(alpha?.state == .running)
	}

	@Test @MainActor func vmGetFallsBackTheSameWay() async throws {
		let rig = try await makeRig()
		defer { finish(rig) }
		_ = try await rig.routing.vm(named: "alpha")
		rig.alpha.stalled = ["vm"]

		let clock = ContinuousClock()
		let started = clock.now
		let alpha = try await rig.routing.vm(named: "alpha")
		#expect(clock.now - started < .seconds(2))
		#expect(alpha.unresponsive == true)
		#expect(alpha.state == .running)
	}

	@Test @MainActor func operationsSkipAStalledHost() async throws {
		let rig = try await makeRig()
		defer { finish(rig) }
		var opA = Samples.copyOperation(vm: "alpha")
		opA.id = "op-alpha"
		var opB = Samples.copyOperation(vm: "beta")
		opB.id = "op-beta"
		rig.alpha.ops = [opA]
		rig.beta.ops = [opB]
		rig.alpha.stalled = ["operations"]

		let clock = ContinuousClock()
		let started = clock.now
		let ops = try await rig.routing.operations()
		#expect(clock.now - started < .seconds(2))
		#expect(ops.map(\.id) == ["op-beta"])
	}

	// The desktop lists only on listChanged, so a stall nobody lists would go unseen; the
	// preview poll is the read that keeps coming. A preview that misses the deadline checks
	// the host the way a list does, and a marked host is not asked for previews at all.
	@Test @MainActor func aStalledPreviewMarksTheHost() async throws {
		let rig = try await makeRig()
		defer { finish(rig) }
		_ = try await rig.routing.listVMs()
		rig.alpha.stalled = ["preview", "vm"]

		let clock = ContinuousClock()
		let started = clock.now
		#expect(try await rig.routing.preview(vm: "alpha", maxWidth: nil) == nil)
		#expect(clock.now - started < .seconds(2))
		#expect(rig.routing.hostForTesting("alpha")?.unresponsive == true)

		let asked = rig.alpha.calls.filter { $0 == "preview" }.count
		#expect(try await rig.routing.preview(vm: "alpha", maxWidth: nil) == nil)
		#expect(rig.alpha.calls.filter { $0 == "preview" }.count == asked)
	}
}
