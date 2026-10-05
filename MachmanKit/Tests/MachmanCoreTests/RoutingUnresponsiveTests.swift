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
			let socketPath = TestEnvironment.socketPath("mm-stall-\(name)")
			let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
			try startServing(server)
			let identity = RoutingMachman.HostIdentity(
				id: UUID(), name: name, socketPath: socketPath)
			let client = try await routing.connectHost(identity: identity)
			routing.adopt(identity: identity, client: client)
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

	// E39: a VM deleted or renamed while the list waited on a host's answer failed the whole
	// list ("No VM named …"), and the desktop showed a list problem.
	@Test @MainActor func aVMThatVanishesDuringTheProbesIsLeftOut() async throws {
		let gamma = "vanish-\(UUID().uuidString)"
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for (name, ran) in [("alpha", Date()), (gamma, nil)] as [(String, Date?)] {
				try VMConfig.createNewVMDirectory(name: name)
				let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
				cfg.lastRan = ran   // alpha lists first, so gamma is read after alpha's wait
				try cfg.saveVMConfig()
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
		}
		routing.hostProbeDeadline = .seconds(10)
		let socketPath = TestEnvironment.socketPath("mm-vanish")
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		defer {
			stub.stalled = []
			server.stop()
		}
		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath)
		routing.adopt(identity: identity, client: try await routing.connectHost(identity: identity))
		stub.stalled = ["vm"]
		let asked = stub.calls.filter { $0 == "vm" }.count

		let listing = Task { try await routing.listVMs() }
		#expect(await eventually { stub.calls.filter { $0 == "vm" }.count > asked })
		routing.registry.reload(name: gamma)   // its folder is gone: deleted under the list
		stub.stalled = []
		let list = try await listing.value   // before: notFound for the whole list
		#expect(list.map(\.name) == ["alpha"])
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

	// safeSave re-keys the host under the new name; a stall right after it serves the host's
	// answer for the promoted VM, never the last answer that still names the original.
	@Test @MainActor func aSafeSavedHostStallsUnderItsNewName() async throws {
		let rig = try await makeRig()
		defer { finish(rig) }
		rig.routing.hostForTesting("alpha")?.identity.isSafe = true
		rig.alpha.vms["alpha"]?.safeRun = true
		_ = try await rig.routing.listVMs()   // the last answer names alpha
		_ = try await rig.routing.safeSave(vm: "alpha", to: "gamma")
		rig.alpha.stalled = ["vm"]

		let gamma = try await rig.routing.vm(named: "gamma")
		#expect(gamma.unresponsive == true)
		#expect(gamma.name == "gamma")   // before: "alpha", a second row for the original
		#expect(gamma.state == .running)
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

	// E40: op.cancel asked the vmhosts one at a time with the 30 s default, so a stalled host
	// held a cancel meant for another, and an unknown id failed with timeout, not notFound.
	@Test @MainActor func aCancelReachesItsHostPastAStalledOne() async throws {
		let rig = try await makeRig(deadline: .seconds(1))
		defer { finish(rig) }
		var op = Samples.copyOperation(vm: "beta")
		op.id = "op-beta"
		rig.beta.ops = [op]
		rig.alpha.stalled = ["cancelOperation"]

		let clock = ContinuousClock()
		let started = clock.now
		try await rig.routing.cancelOperation(id: "op-beta")
		#expect(clock.now - started < .seconds(10))   // before: up to 30 s behind alpha
		#expect(rig.beta.ops.isEmpty)
	}

	@Test @MainActor func aCancelNobodyAnswersNamesTheStalledHost() async throws {
		let rig = try await makeRig(deadline: .seconds(1))
		defer { finish(rig) }
		rig.alpha.stalled = ["cancelOperation"]

		let clock = ContinuousClock()
		let started = clock.now
		do {
			try await rig.routing.cancelOperation(id: "op-unknown")
			Issue.record("expected a refusal")
		} catch let error as MachmanError {
			// Before: timeout after 30 s. The op may run on the host that didn't answer.
			#expect(error.code == .invalidState)
			#expect(error.message == "alpha is not responding \u{2014} try again in a moment")
		}
		#expect(clock.now - started < .seconds(10))

		rig.alpha.stalled = []
		await #expect(throws: MachmanError.self) {
			try await rig.routing.cancelOperation(id: "op-unknown")
		}
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
