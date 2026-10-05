//
//  SafeSaveSSHTests.swift
//  MachmanTests
//
//  C27: Save as New VM adds a VM to the library, but the daemon's half never regenerated
//  ~/.ssh/machman, so the file kept describing the library as it was until some unrelated
//  trigger. Its end now schedules the rewrite. Observed through a scratch ~/.ssh whose stale
//  managed file the rewrite removes (no VM here uses SSH).
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct SafeSaveSSHTests {
	@Test @MainActor func aSaveRewritesTheManagedSSHConfig() async throws {
		let sshDir = URL(fileURLWithPath: TestEnvironment.scratch)
			.appendingPathComponent("save-ssh-\(UUID().uuidString)")
		let managed = sshDir.appendingPathComponent("machman/config")
		try FileManager.default.createDirectory(
			at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data("Host \"stale\"\n".utf8).write(to: managed)
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2).saveVMConfig()
			routing = RoutingMachman(
				registry: VMRegistry(), daemonVersion: "test",
				sshHostConfig: SSHHostConfigWriter(sshDir: sshDir))
		}
		let socketPath = TestEnvironment.socketPath("mm-save-ssh")
		let stub = StubMachman()
		var alpha = StubMachman.makeInfo("alpha", state: .running)
		alpha.safeRun = true
		stub.vms["alpha"] = alpha
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		defer { server.stop() }
		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath, isSafe: true)
		routing.adopt(identity: identity, client: try await routing.connectHost(identity: identity))
		#expect(FileManager.default.fileExists(atPath: managed.path))

		_ = try await routing.safeSave(vm: "alpha", to: "gamma")
		// Before: nothing rewrote it after the save.
		#expect(await eventually { !FileManager.default.fileExists(atPath: managed.path) })
	}
}
