//
//  RoutingRetireTests.swift
//  MachmanTests
//
//  E45: daemon.retire (every Replace) exited 200 ms after replying, and whatever the daemon
//  ran itself died with it — a macOS install (its half-downloaded restore image then swept by
//  the successor), a copy, a stopped VM's import, a safe start's shadow build. Retire now
//  refuses while such work runs, naming it; vmhosts and the copies they run keep going.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

@MainActor
private final class RetireCount {
	var retired = 0
}

struct RoutingRetireTests {
	@MainActor
	private func makeRouting() throws -> (RoutingMachman, RetireCount) {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2).saveVMConfig()
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
		}
		let count = RetireCount()
		routing.onRetire = { count.retired += 1 }
		return (routing, count)
	}

	@Test @MainActor func workInTheDaemonHoldsARetire() async throws {
		for (kind, refusal) in [
			(VMClaims.Kind.starting, "alpha is starting — try again when it finishes"),
			(.importingDisk, "alpha is importing a disk — try again when it finishes"),
			(.copying, "alpha is being copied — try again when it finishes"),
		] {
			let (routing, count) = try makeRouting()
			routing.claims.insert("alpha", kind)
			do {
				try await routing.retire()
				Issue.record("retired while \(kind) ran in the daemon")
			} catch let error as MachmanError {
				#expect(error.code == .invalidState)
				#expect(error.message == refusal)
			}
			#expect(count.retired == 0)
		}
	}

	// A copy proxied to a vmhost runs there and outlives the daemon: no reason to wait.
	@Test @MainActor func aCopyInAVMHostDoesNot() async throws {
		let (routing, count) = try makeRouting()
		routing.claims.insert("alpha", .importingDisk, inDaemon: false)
		try await routing.retire()
		#expect(await eventually { count.retired == 1 })
	}

	@Test @MainActor func aMacOSInstallHoldsARetire() throws {
		var stillRunning: (() -> Void)?
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "mac")
			try VMConfig(name: "mac", memorySize: 2048, cpuCount: 2).saveVMConfig()
			let registry = VMRegistry()
			var open = false
			registry.installRunner = { _, _ in
				while !open { try await Task.sleep(for: .milliseconds(10)) }
				throw CocoaError(.userCancelled)
			}
			stillRunning = { open = true }
			let routing = RoutingMachman(registry: registry, daemonVersion: "test")
			#expect(routing.daemonWorkRefusal() == nil)
			try registry.installSession(for: #require(registry.vm(named: "mac")))
				.startInstall(source: InstallSource(kind: .ipsw, path: "/nonexistent.ipsw"))
			let refusal = try #require(routing.daemonWorkRefusal())
			#expect(refusal.code == .invalidState)
			#expect(refusal.message == "mac is installing macOS — try again when it finishes")
		}
		stillRunning?()
	}
}
