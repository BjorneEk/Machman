//
//  MacConflictTests.swift
//  MachmanTests
//
//  The router's MAC-conflict guard, exercised with an adopted stub host — no VZ, no spawn.
//  Config/registry setup happens inside the redirected-dir lock (synchronous); the async
//  socket work runs after it, touching only in-memory state.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct MacConflictTests {
	@MainActor
	private func makeRouting(sharedMAC: String) throws -> RoutingMachman {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in ["alpha", "beta"] {
				try VMConfig.createNewVMDirectory(name: name)
				let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
				cfg.macAddress = sharedMAC
				try cfg.saveVMConfig()
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }   // a test never finds (or launches) a real vmhost
		}
		return routing
	}

	@Test @MainActor func startRefusesWhenAHostedVMUsesTheMAC() async throws {
		let mac = "aa:bb:cc:00:11:22"
		let routing = try makeRouting(sharedMAC: mac)

		let socketPath = TestEnvironment.scratch
			+ "mm-conflict-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }
		let client = try await routing.connectHost(identity: RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath))

		routing.adopt(
			identity: RoutingMachman.HostIdentity(
				id: UUID(), name: "alpha", socketPath: socketPath, macInUse: mac),
			client: client)

		do {
			try await routing.start(vm: "beta", options: StartOptions())
			Issue.record("expected macConflict")
		} catch let error as MachmanError {
			#expect(error.code == .macConflict)
			#expect(error.message.contains("alpha"))
		}
		await client.disconnect()
	}

	@Test @MainActor func forceBypassesTheMacConflictGuard() async throws {
		let mac = "aa:bb:cc:00:33:44"
		let routing = try makeRouting(sharedMAC: mac)

		let socketPath = TestEnvironment.scratch
			+ "mm-force-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }
		let client = try await routing.connectHost(identity: RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath))
		routing.adopt(
			identity: RoutingMachman.HostIdentity(
				id: UUID(), name: "alpha", socketPath: socketPath, macInUse: mac),
			client: client)

		do {
			try await routing.start(vm: "beta", options: StartOptions(force: true))
			Issue.record("expected a spawn failure in the test host")
		} catch let error as MachmanError {
			// Force got past the guard: the failure is the unreachable spawn path
			// (no embedded vmhost in the test host), not macConflict.
			#expect(error.code != .macConflict)
		}
		await client.disconnect()
	}
}
