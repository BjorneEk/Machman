//
//  ReverseKeyRevokeTests.swift
//  MachmanTests
//
//  D11: vm.delete revokes the VM's guest→Mac grant in ~/.ssh/authorized_keys. A revoke
//  that fails (here: a directory the edit can't write its temporary file into) is surfaced
//  as a warning event naming the line to remove — it used to vanish in a try?. C21: deny,
//  revoke, reset and a re-keyed guest go through the same revoke, and an approval whose line
//  the Mac refuses is refused itself instead of reading as approved.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
import MachmanFixtures
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

	// MARK: - Approving (C21)

	private let guestKey = "ssh-ed25519 GUESTKEY guest"

	// A stub owner whose VM reported a reverse key that awaits approval.
	private func owner() -> StubMachman {
		let stub = StubMachman()
		var vm = StubMachman.makeInfo("dev", state: .running)
		vm.ssh = SSHInfo(reverseState: .pending, reversePublicKey: guestKey)
		stub.vms["dev"] = vm
		return stub
	}

	private func approve(_ routing: RoutingMachman, on stub: StubMachman) async throws -> VMInfo {
		try await routing.approveReverseKey(vm: "dev", marker: "machman-abc", on: stub) {
			try await stub.setSSH(
				vm: "dev", integrationEnabled: nil, reverseApproved: true, alias: nil)
		}
	}

	@Test func anApprovalInstallsTheLine() async throws {
		let mine = "ssh-ed25519 MINE user@mac\n"
		let dir = try sshDir(grant: mine)
		defer { try? FileManager.default.removeItem(at: dir) }
		let (routing, _) = try routing(sshDir: dir)
		let stub = owner()

		let info = try await approve(routing, on: stub)
		#expect(info.ssh?.reverseState == .approved)
		#expect(try String(contentsOf: dir.appendingPathComponent("authorized_keys"),
			encoding: .utf8) == mine + guestKey + " machman:machman-abc:dev\n")
	}

	@Test func aLineTheMacRefusesRefusesTheApproval() async throws {
		let mine = "ssh-ed25519 MINE user@mac\n"
		let dir = try sshDir(grant: mine)
		let fm = FileManager.default
		try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
		defer {
			try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
			try? fm.removeItem(at: dir)
		}
		let (routing, _) = try routing(sshDir: dir)
		let stub = owner()

		do {
			_ = try await approve(routing, on: stub)
			Issue.record("expected the approval to be refused")
		} catch let error as MachmanError {
			#expect(error.code == .ioFailure)
			#expect(error.message.hasPrefix("Couldn’t write "))
		}
		#expect(!stub.calls.contains("setSSH"))   // nothing recorded
		#expect(stub.vms["dev"]?.ssh?.reverseState == .pending)
		#expect(try String(contentsOf: dir.appendingPathComponent("authorized_keys"),
			encoding: .utf8) == mine)
	}

	@Test func aRecordThatFailsTakesTheLineBackOut() async throws {
		let mine = "ssh-ed25519 MINE user@mac\n"
		let dir = try sshDir(grant: mine)
		defer { try? FileManager.default.removeItem(at: dir) }
		let (routing, _) = try routing(sshDir: dir)
		let stub = owner()
		stub.fail("setSSH", with: MachmanError(code: .ioFailure, message: "disk full"))

		await #expect(throws: MachmanError.self) { _ = try await approve(routing, on: stub) }
		#expect(try String(contentsOf: dir.appendingPathComponent("authorized_keys"),
			encoding: .utf8) == mine)
	}

	// MARK: - Review F5: an unreadable authorized_keys, said once and only where a line can be

	// The warning events a body raises, up to a sentinel behind it.
	private func warnings(
		_ registry: VMRegistry, _ body: () async -> Void
	) async -> [String] {
		var events = registry.events.stream().makeAsyncIterator()
		await body()
		registry.events.emit(.listChanged)
		var messages: [String] = []
		while let event = await events.next() {
			if case .log(_, .warning, let message) = event { messages.append(message) }
			if case .listChanged = event { break }
		}
		return messages
	}

	private func unreadableKeys() throws -> URL {
		let dir = try sshDir(grant: "ssh-ed25519 MINE user@mac\n")
		let keys = dir.appendingPathComponent("authorized_keys").path
		try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: keys)
		return dir
	}

	private func cleanUp(_ dir: URL) {
		let keys = dir.appendingPathComponent("authorized_keys").path
		try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keys)
		try? FileManager.default.removeItem(at: dir)
	}

	// Reconcile runs at every report of every VM with SSH state. One that never had a reverse
	// key can't have a line, so an unreadable file is not its warning to raise.
	@Test func anUnreadableFileIsNotBlamedOnAVMWithoutAKey() async throws {
		let dir = try unreadableKeys()
		defer { cleanUp(dir) }
		let (routing, registry) = try routing(sshDir: dir)
		let stub = StubMachman()
		var vm = StubMachman.makeInfo("dev", state: .running)
		vm.ssh = SSHInfo(
			configured: true, guestUser: "admin", reverseState: SSHInfo.ReverseState.none)
		stub.vms["dev"] = vm

		let raised = await warnings(registry) {
			await routing.reconcileReverseKey(vm: "dev", marker: "machman-abc", owner: stub)
			await routing.reconcileReverseKey(vm: "dev", marker: "machman-abc", owner: stub)
		}
		#expect(raised.isEmpty)
	}

	// A VM whose key is on file can have a line: said once, as a file that can't be read.
	@Test func anUnreadableFileIsSaidOncePerVM() async throws {
		let dir = try unreadableKeys()
		defer { cleanUp(dir) }
		let (routing, registry) = try routing(sshDir: dir)
		let stub = owner()   // pending, key on file

		let raised = await warnings(registry) {
			for _ in 0..<3 {
				await routing.reconcileReverseKey(vm: "dev", marker: "machman-abc", owner: stub)
			}
		}
		#expect(raised == ["Couldn’t read ~/.ssh/authorized_keys to remove the guest’s key"])
	}

	// A line that stays is said once per VM, not at every report.
	@Test func aStuckLineIsSaidOnce() async throws {
		let grant = "ssh-ed25519 AAAA guest machman:machman-abc:dev\n"
		let dir = try sshDir(grant: grant)
		let fm = FileManager.default
		try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
		defer {
			try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
			try? fm.removeItem(at: dir)
		}
		let (routing, registry) = try routing(sshDir: dir)

		let raised = await warnings(registry) {
			routing.revokeReverseKey(marker: "machman-abc", vmName: "dev")
			routing.revokeReverseKey(marker: "machman-abc", vmName: "dev")
		}
		#expect(raised.count == 1)
		#expect(raised.first?.contains("machman:machman-abc:dev") == true)
	}
}
