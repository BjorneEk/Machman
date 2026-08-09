//
//  RoutingProbeAdoptTests.swift
//  MachmanTests
//
//  The router's probe-and-adopt path (start() meeting a socket a launchd-started vmhost
//  already owns), exercised through the internal seam with an injected socket path — no VZ,
//  no spawn, no dependency on the global runtime dir at async time. Config/registry setup
//  happens inside the redirected-dir lock (synchronous), same pattern as MacConflictTests.
//

import Testing
import Foundation
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct RoutingProbeAdoptTests {
	@MainActor
	private func makeRouting() throws -> RoutingMachman {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			let cfg = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			try cfg.saveVMConfig()
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
		}
		return routing
	}

	@Test @MainActor func startAdoptsALiveHostAndForwardsTheStart() async throws {
		let routing = try makeRouting()
		let socketPath = NSTemporaryDirectory()
			+ "mm-probe-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		let handled = try await routing.probeAdoptAndStart(
			name: "alpha", socketPath: socketPath, options: StartOptions(openConsole: false))
		#expect(handled)
		#expect(routing.hostedNames == ["alpha"])
		#expect(stub.vms["alpha"]?.state == .running)   // the start reached the host
	}

	@Test @MainActor func adoptOfARunningHostToleratesInvalidState() async throws {
		let routing = try makeRouting()
		let socketPath = NSTemporaryDirectory()
			+ "mm-probe2-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }

		// The host refuses the forwarded start (already running); the probe still adopts
		// and honors openConsole so the caller gets what they asked for.
		let handled = try await routing.probeAdoptAndStart(
			name: "alpha", socketPath: socketPath, options: StartOptions(openConsole: true))
		#expect(handled)
		#expect(routing.hostedNames == ["alpha"])
		#expect(stub.consoleOpens == 1)
	}

	@Test @MainActor func deadSocketIsReclaimedAndNotAdopted() async throws {
		let routing = try makeRouting()
		let socketPath = NSTemporaryDirectory()
			+ "mm-dead-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		FileManager.default.createFile(atPath: socketPath, contents: nil)

		let handled = try await routing.probeAdoptAndStart(
			name: "alpha", socketPath: socketPath, options: StartOptions())
		#expect(!handled)                                              // caller spawns fresh
		#expect(!FileManager.default.fileExists(atPath: socketPath))   // leftover reclaimed
		#expect(routing.hostedNames.isEmpty)
	}
}
