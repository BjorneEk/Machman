//
//  ReverseKeyRevokeTests.swift
//  MachmanTests
//
//  D11: vm.delete revokes the VM's guest→Mac grant in ~/.ssh/authorized_keys. A revoke
//  that fails (here: a directory the edit can't write its temporary file into) is surfaced
//  as a warning event naming the line to remove — it used to vanish in a try?.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
@testable import MachmanCore

@MainActor
struct ReverseKeyRevokeTests {
	private func sshDir(grant: String) throws -> URL {
		let dir = TestEnvironment.scratchURL
			.appendingPathComponent("revoke-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try grant.write(
			to: dir.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
		return dir
	}

	private func routing(sshDir: URL) throws -> (RoutingMachman, VMRegistry) {
		var result: (RoutingMachman, VMRegistry)!
		try VMTestDir.withRedirectedDir {
			let registry = VMRegistry()
			result = (
				RoutingMachman(
					registry: registry, daemonVersion: "test",
					sshHostConfig: SSHHostConfigWriter(sshDir: sshDir)),
				registry)
		}
		return result
	}

	@Test func aFailedRevokeIsSurfaced() async throws {
		let grant = "ssh-ed25519 AAAA guest machman:machman-abc:dev\n"
		let dir = try sshDir(grant: grant)
		let fm = FileManager.default
		try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
		defer {
			try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
			try? fm.removeItem(at: dir)
		}
		let (routing, registry) = try routing(sshDir: dir)
		var events = registry.events.stream().makeAsyncIterator()

		routing.revokeReverseKey(marker: "machman-abc", vmName: "dev")
		// A sentinel behind it: the first event is the warning, or the test fails instead
		// of waiting forever.
		registry.events.emit(.listChanged)
		guard case .log(let vm, let level, let message) = await events.next() else {
			Issue.record("expected a warning event first")
			return
		}
		#expect(vm == "dev")
		#expect(level == .warning)
		#expect(message.contains("machman:machman-abc:dev"))
		#expect(try String(contentsOf: dir.appendingPathComponent("authorized_keys"),
			encoding: .utf8) == grant)
	}

	@Test func aRevokeRemovesTheGrantLine() throws {
		let mine = "ssh-ed25519 MINE user@mac\n"
		let dir = try sshDir(grant: mine + "ssh-ed25519 AAAA guest machman:machman-abc:dev\n")
		defer { try? FileManager.default.removeItem(at: dir) }
		let (routing, _) = try routing(sshDir: dir)

		routing.revokeReverseKey(marker: "machman-abc", vmName: "dev")
		#expect(try String(contentsOf: dir.appendingPathComponent("authorized_keys"),
			encoding: .utf8) == mine)
	}
}
