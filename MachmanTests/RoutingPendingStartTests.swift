//
//  RoutingPendingStartTests.swift
//  MachmanTests
//
//  The router's start-window reservation: `hosted` is written only after the spawn (and,
//  for safe runs, a possibly minutes-long shadow build), so pendingStarts is what makes a
//  booting VM visible to every guard in the window. Exercised through the internal seam
//  (tests reserve a name directly) plus real start() calls whose spawn fails in the test
//  host — no VZ, no vmhost. Setup runs inside the redirected-dir lock (synchronous), the
//  async surface touches only in-memory state (MacConflictTests pattern).
//

import Testing
import Foundation
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct RoutingPendingStartTests {
	@MainActor
	private func makeRouting(names: [String], mac: String? = nil) throws -> RoutingMachman {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in names {
				try VMConfig.createNewVMDirectory(name: name)
				let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
				if let mac { cfg.macAddress = mac }
				try cfg.saveVMConfig()
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
		}
		return routing
	}

	// E1: the loser of two concurrent starts must be refused, never adopt-and-kill the
	// winner's half-spawned vmhost.
	@Test @MainActor func secondStartIsRefusedWhileAStartIsPending() async throws {
		let routing = try makeRouting(names: ["pending-alpha"])
		routing.pendingStarts.insert("pending-alpha")

		do {
			try await routing.start(vm: "pending-alpha", options: StartOptions())
			Issue.record("expected invalidState")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message.contains("already starting"))
		}
	}

	// E2: whole-VM operations must see a pending start as running — the vmhost is (or is
	// about to be) reading the very files they would move or delete.
	@Test @MainActor func guardedOpsRefuseWhileAStartIsPending() async throws {
		let routing = try makeRouting(names: ["pending-alpha"])
		routing.pendingStarts.insert("pending-alpha")

		let ops: [(String, () async throws -> Void)] = [
			("delete", { try await routing.deleteVM(named: "pending-alpha") }),
			("rename", { try await routing.renameVM(named: "pending-alpha", to: "x") }),
			("copy", { _ = try await routing.copyVM(
				vm: "pending-alpha", newName: nil, diskIDs: nil, regenerateMAC: true) }),
			("regenerateMAC", { _ = try await routing.regenerateMAC(vm: "pending-alpha") }),
			("resizeDisk", { _ = try await routing.resizeDisk(
				vm: "pending-alpha", diskID: "storage:disk", sizeBytes: 1) }),
			("consoleAdd", { try await routing.addConsolePort(vm: "pending-alpha") }),
			("installStart", { try await routing.startMacInstall(
				vm: "pending-alpha", source: .latest) }),
		]
		for (label, op) in ops {
			do {
				try await op()
				Issue.record("\(label): expected invalidState while a start is pending")
			} catch let error as MachmanError {
				#expect(error.code == .invalidState, "\(label) carried \(error.code)")
			}
		}
	}

	// The reservation must be released when a start throws after claiming the name —
	// here at the MAC-conflict guard (first throw site past the insert).
	@Test @MainActor func reservationIsReleasedWhenTheStartIsRefused() async throws {
		let mac = "aa:bb:cc:77:11:22"
		let routing = try makeRouting(names: ["pending-alpha", "pending-beta"], mac: mac)

		let socketPath = NSTemporaryDirectory()
			+ "mm-pend-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["pending-alpha"] = StubMachman.makeInfo("pending-alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }
		let client = try await routing.connectHost(identity: RoutingMachman.HostIdentity(
			id: UUID(), name: "pending-alpha", socketPath: socketPath))
		routing.adopt(
			identity: RoutingMachman.HostIdentity(
				id: UUID(), name: "pending-alpha", socketPath: socketPath, macInUse: mac),
			client: client)

		do {
			try await routing.start(vm: "pending-beta", options: StartOptions())
			Issue.record("expected macConflict")
		} catch let error as MachmanError {
			#expect(error.code == .macConflict)
		}
		#expect(routing.pendingStarts.isEmpty)
		await client.disconnect()
	}

	// …and when it fails deeper in: past purge and probe, at the spawn itself (the test
	// host embeds no MachmanVMHost.app, so the spawn path is the failure).
	@Test @MainActor func reservationIsReleasedWhenTheSpawnFails() async throws {
		let routing = try makeRouting(names: ["pending-gamma"])

		do {
			try await routing.start(vm: "pending-gamma", options: StartOptions())
			Issue.record("expected a spawn failure in the test host")
		} catch let error as MachmanError {
			#expect(error.code == .internalError)
		}
		#expect(routing.pendingStarts.isEmpty)
		#expect(routing.hostedNames.isEmpty)
	}
}
