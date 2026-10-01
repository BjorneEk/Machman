//
//  RoutingIdleHostTests.swift
//  MachmanTests
//
//  E12: a daemon that died between spawning a vmhost and forwarding its start leaves the host
//  idle; the next daemon adopts it, and Start answered "already running" for a stopped VM
//  until the host's 3-minute idle exit. A start now asks the adopted host first: an idle one
//  gets the start, a running one still refuses, one exiting after a stop is waited out.
//  Stub hosts adopted over scratch sockets; registry setup inside the redirected-dir lock.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct RoutingIdleHostTests {
	private struct Rig {
		let routing: RoutingMachman
		let stub: StubMachman
		let server: MachmanServer
		let socketPath: String
	}

	@MainActor
	private func makeRouting(names: [String] = ["alpha"], mac: String? = nil) throws
		-> RoutingMachman {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in names {
				try VMConfig.createNewVMDirectory(name: name)
				let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
				if let mac { cfg.macAddress = mac }
				try cfg.saveVMConfig()
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }   // a test never finds (or launches) a real vmhost
		}
		routing.hostProbeDeadline = .milliseconds(300)
		routing.hostExitGrace = .milliseconds(300)
		routing.isProcessAlive = { _ in false }   // a stub host's exit is its server stopping
		return routing
	}

	// A stub host serving `name` in `state`, adopted the way startup adoption does it.
	@MainActor
	private func adoptStub(
		_ routing: RoutingMachman, _ name: String = "alpha", state: VMState,
		mac: String? = nil
	) async throws -> Rig {
		let socketPath = TestEnvironment.scratch
			+ "mm-idle-\(name)-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms[name] = StubMachman.makeInfo(name, state: state)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: name, socketPath: socketPath, macInUse: mac)
		let client = try await routing.connectHost(identity: identity)
		routing.adopt(identity: identity, client: client)
		return Rig(routing: routing, stub: stub, server: server, socketPath: socketPath)
	}

	@Test @MainActor func startHandsTheStartToAnIdleAdoptedHost() async throws {
		let rig = try await adoptStub(try makeRouting(), state: .stopped)
		defer { rig.server.stop() }

		try await rig.routing.start(vm: "alpha", options: StartOptions(openWindow: false))
		#expect(rig.stub.starts.count == 1)   // before: "alpha is already running"
		#expect(rig.stub.vms["alpha"]?.state == .running)
		#expect(rig.routing.hostForTesting("alpha")?.sawRun == true)
		#expect(rig.routing.pendingStarts.isEmpty)
	}

	@Test @MainActor func startStillRefusesARunningHost() async throws {
		let rig = try await adoptStub(try makeRouting(), state: .running)
		defer { rig.server.stop() }

		do {
			try await rig.routing.start(vm: "alpha", options: StartOptions())
			Issue.record("expected invalidState")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message.contains("already running"))
		}
		#expect(rig.stub.starts.isEmpty)
	}

	@Test @MainActor func startRefusesAnUnansweringHost() async throws {
		let rig = try await adoptStub(try makeRouting(), state: .stopped)
		defer {
			rig.stub.stalled = []
			rig.server.stop()
		}
		rig.stub.stalled = ["vm"]

		let clock = ContinuousClock()
		let started = clock.now
		do {
			try await rig.routing.start(vm: "alpha", options: StartOptions())
			Issue.record("expected invalidState")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message.contains("not responding"))
		}
		#expect(clock.now - started < .seconds(2))
		#expect(rig.stub.starts.isEmpty)
	}

	// A forwarded start runs the real VM, never a shadow — so a safe start must not quietly
	// turn into a plain run of an idle host (probe-adopt used to do exactly that).
	@Test @MainActor func aSafeStartNeverRunsAnIdleHostUnsafely() async throws {
		let rig = try await adoptStub(try makeRouting(), state: .stopped)
		defer { rig.server.stop() }
		do {
			try await rig.routing.start(vm: "alpha", options: StartOptions(safe: true))
			Issue.record("expected invalidState")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message.contains("idle vmhost"))
		}
		#expect(rig.stub.starts.isEmpty)

		// The same through the probe-adopt path (a live socket the daemon has not adopted).
		let routing = try makeRouting()
		let socketPath = TestEnvironment.scratch
			+ "mm-idle-probe-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .stopped)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }
		do {
			_ = try await routing.probeAdoptAndStart(
				name: "alpha", socketPath: socketPath, options: StartOptions(safe: true))
			Issue.record("expected invalidState")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
		}
		#expect(stub.starts.isEmpty)   // before: forwarded as a plain start
	}

	// A host that ran and stopped is exiting (its 300 ms flush): forwarding a start to it
	// would be killed with it. The start waits the exit out, and refuses if it overstays.
	@Test @MainActor func anExitingHostIsAwaitedNotForwarded() async throws {
		let rig = try await adoptStub(try makeRouting(), state: .stopped)
		defer { rig.server.stop() }
		rig.routing.hostForTesting("alpha")?.sawRun = true

		do {
			try await rig.routing.start(vm: "alpha", options: StartOptions())
			Issue.record("expected invalidState")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message.contains("still shutting down"))
		}
		#expect(rig.stub.starts.isEmpty)
	}

	// A host adopted while it missed its deadline has no reply to learn the run from, and a
	// VM already running sends no running event. A later answer showing it running must
	// count: once that VM stops, a start waits the exit out instead of being forwarded.
	@Test @MainActor func aRunningAnswerAfterAdoptionCountsAsARun() async throws {
		let rig = try await adoptStub(try makeRouting(), state: .running)
		defer { rig.server.stop() }
		#expect(rig.routing.hostForTesting("alpha")?.sawRun == false)   // as a timed-out reply
		_ = try await rig.routing.listVMs()
		#expect(rig.routing.hostForTesting("alpha")?.sawRun == true)
		rig.stub.vms["alpha"]?.state = .stopped   // the VM stops; its host is exiting

		do {
			try await rig.routing.start(vm: "alpha", options: StartOptions())
			Issue.record("expected invalidState")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message.contains("still shutting down"))
		}
		#expect(rig.stub.starts.isEmpty)   // before: forwarded to the exiting host
	}

	@Test @MainActor func aHostThatExitsDuringTheGraceIsReplaced() async throws {
		let rig = try await adoptStub(try makeRouting(), state: .stopped)
		rig.routing.hostForTesting("alpha")?.sawRun = true
		let server = rig.server
		Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(100))
			server.stop()   // the host exits inside the grace
		}

		do {
			try await rig.routing.start(vm: "alpha", options: StartOptions())
			Issue.record("expected the fresh-start path to fail in the test host")
		} catch let error as MachmanError {
			// Past the exiting host: the fresh-start path, which a test host cannot finish.
			#expect(!error.message.contains("still shutting down"))
			#expect(!error.message.contains("already running"))
		}
		#expect(rig.stub.starts.isEmpty)
		#expect(rig.routing.hostedNames.isEmpty)
	}

	@Test @MainActor func anIdleHostsMACStillConflicts() async throws {
		let mac = "aa:bb:cc:77:99:00"
		let routing = try makeRouting(names: ["alpha", "beta"], mac: mac)
		let beta = try await adoptStub(routing, "beta", state: .running, mac: mac)
		defer { beta.server.stop() }
		let alpha = try await adoptStub(routing, "alpha", state: .stopped, mac: mac)
		defer { alpha.server.stop() }

		do {
			try await routing.start(vm: "alpha", options: StartOptions())
			Issue.record("expected macConflict")
		} catch let error as MachmanError {
			#expect(error.code == .macConflict)
			#expect(error.message.contains("beta"))
		}
		#expect(alpha.stub.starts.isEmpty)
	}
}
