//
//  RoutingClaimTests.swift
//  MachmanTests
//
//  E33 and D20: a disk or kernel copy into a VM checked the VM's owner once, then waited
//  minutes on the byte copy and wrote the config at the end. A start meanwhile launched a
//  vmhost on the old config whose own saves reverted the import; a rename, delete or copy
//  moved or read the folder under it. The copy now holds a claim on the VM for its whole
//  run. Staged claims through the seam, and one real copy held open in a stub vmhost.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct RoutingClaimTests {
	@MainActor
	private func makeRouting(names: [String] = ["alpha"]) throws -> RoutingMachman {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in names {
				try VMConfig.createNewVMDirectory(name: name)
				try VMConfig(name: name, memorySize: 2048, cpuCount: 2).saveVMConfig()
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }   // a test never finds (or launches) a real vmhost
		}
		routing.hostProbeDeadline = .seconds(10)
		return routing
	}

	private static let copies: [(VMClaims.Kind, String)] = [
		(.importingDisk, "alpha is importing a disk — try again when it finishes"),
		(.promotingDisk, "alpha is promoting a disk — try again when it finishes"),
		(.importingKernel, "alpha is importing a kernel file — try again when it finishes"),
		(.copying, "alpha is being copied — try again when it finishes"),
	]

	// Every path that hands the VM to someone else, or moves or reads its folder whole,
	// refuses while a copy holds it.
	@Test @MainActor func aCopyHoldsOffStartsAndWholeVMEdits() async throws {
		for (kind, refusal) in Self.copies {
			let routing = try makeRouting()
			routing.claims.insert("alpha", kind)
			let ops: [(String, () async throws -> Void)] = [
				("start", { try await routing.start(vm: "alpha", options: StartOptions()) }),
				("delete", { try await routing.deleteVM(named: "alpha") }),
				("rename", { try await routing.renameVM(named: "alpha", to: "x") }),
				("copy", { _ = try await routing.copyVM(
					vm: "alpha", newName: nil, diskIDs: nil, regenerateMAC: true) }),
				("promoteDisk", { _ = try await routing.promoteDisk(
					vm: "alpha", diskID: "storage:disk") }),
				("regenerateMAC", { _ = try await routing.regenerateMAC(vm: "alpha") }),
				("removeDisk", { try await routing.removeDisk(
					vm: "alpha", diskID: "storage:disk") }),
				("installStart", { try await routing.startMacInstall(
					vm: "alpha", source: .latest) }),
			]
			for (label, op) in ops {
				do {
					try await op()
					Issue.record("\(label) went through while \(kind) held alpha")
				} catch let error as MachmanError {
					#expect(error.code == .invalidState, "\(label) carried \(error.code)")
					#expect(error.message == refusal, "\(label): \(error.message)")
				}
			}
			#expect(routing.pendingStarts.isEmpty)
		}
	}

	// D18 made concurrent imports into one VM safe (each names its file as it lands), so a
	// second drop goes through; a copy beside either never does.
	@Test @MainActor func copiesThatOnlyAddFilesCoexist() throws {
		let claims = VMClaims()
		let first = try claims.claim("alpha", .importingDisk)
		_ = try claims.claim("alpha", .promotingDisk)
		_ = try claims.claim("alpha", .importingKernel)
		#expect(throws: MachmanError.self) { _ = try claims.claim("alpha", .copying) }
		#expect(throws: MachmanError.self) { _ = try claims.claim("alpha", .starting) }
		claims.release(first)

		let other = VMClaims()
		_ = try other.claim("beta", .copying)
		let error = try #require(throws: MachmanError.self) {
			_ = try other.claim("beta", .importingDisk)
		}
		#expect(error.message == "beta is being copied — try again when it finishes")
	}

	// C14: a VM still preparing a safe run runs nothing yet, so Shut Down and Force Stop
	// cancel the preparation; in the spawn window (no cancel) a stop still waits.
	@Test @MainActor func aStopCancelsASafeRunsPreparation() async throws {
		let routing = try makeRouting()
		let start = routing.claims.insert("alpha", .starting)
		var canceled = 0
		routing.claims.setCancel(start) { canceled += 1 }

		try await routing.stop(vm: "alpha", mode: .soft)
		try await routing.stop(vm: "alpha", mode: .force)
		#expect(canceled == 2)   // before: "alpha is starting — try again once it is running"

		routing.claims.setCancel(start, nil)
		do {
			try await routing.stop(vm: "alpha", mode: .force)
			Issue.record("a stop went through in the spawn window")
		} catch let error as MachmanError {
			#expect(error.message == "alpha is starting — try again once it is running")
		}
		#expect(canceled == 2)
	}

	// Review F9: a Stop that lands as the shadow copy finishes — after the copy's last look at
	// the cancel — still cancels the start; the VM never boots.
	@Test @MainActor func aStopAsTheShadowCopyEndsStillCancels() async throws {
		let routing = try makeRouting()
		var located = 0
		routing.locateVMHost = {
			located += 1
			return nil
		}
		let safeDir = TestEnvironment.scratch + "safe-\(UUID().uuidString)"
		routing.safeRunsDir = { safeDir }
		routing.copyShadow = { _ in try await routing.stop(vm: "alpha", mode: .force) }

		do {
			try await routing.start(vm: "alpha", options: StartOptions(safe: true))
			Issue.record("the start went on after its stop")
		} catch let error as MachmanError {
			#expect(error.message == "The safe run was canceled")
			#expect(error.code == .cancelled)   // a never-mind for clients (review F11)
		}
		#expect(located == 0)   // before: on to the spawn
		#expect(((try? FileManager.default.contentsOfDirectory(atPath: safeDir)) ?? []).isEmpty)
		let card = routing.local.operationCenter.list()
			.first { $0.kind == OperationInfo.Kind.shadowBuild }
		#expect(card?.state == OperationInfo.State.cancelled)
	}

	// The real window: an import into a VM whose idle vmhost does the copy (it proxies while
	// hosted). Before, a start during it was forwarded to that host and the VM booted on the
	// config the import was about to change.
	@Test @MainActor func aStartWaitsForAnImportInFlight() async throws {
		let routing = try makeRouting()
		let socketPath = TestEnvironment.socketPath("mm-claim")
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .stopped)
		stub.stalled = ["importDisk"]
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		defer {
			stub.stalled = []
			server.stop()
		}
		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath)
		routing.adopt(identity: identity, client: try await routing.connectHost(identity: identity))

		let importing = Task { try await routing.importDisk(vm: "alpha", path: "/images/a.img") }
		#expect(await eventually { stub.calls.contains("importDisk") })
		do {
			try await routing.start(vm: "alpha", options: StartOptions(openWindow: false))
			Issue.record("the start went through while the import ran")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message == "alpha is importing a disk — try again when it finishes")
		}
		#expect(stub.starts.isEmpty)
		// The proxied copy runs in the vmhost: it never holds up a daemon replacement.
		#expect(routing.claims.claims(on: "alpha").map(\.inDaemon) == [false])

		stub.stalled = []
		_ = try await importing.value
		#expect(routing.claims.claims(on: "alpha").isEmpty)
		try await routing.start(vm: "alpha", options: StartOptions(openWindow: false))
		#expect(stub.starts.count == 1)
	}
}
