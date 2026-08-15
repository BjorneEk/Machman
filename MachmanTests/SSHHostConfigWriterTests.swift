//
//  SSHHostConfigWriterTests.swift
//  MachmanTests
//
//  The ~/.ssh writer against a temp root (never the real ~/.ssh): Include-line surgery,
//  whole-file regeneration with last-known-address fallback, alias-keyed pinning with
//  the accept-new fallback, quoting, and exact-match authorized_keys add/remove.
//

import Testing
import Foundation
@testable import MachmanCore

struct SSHHostConfigWriterTests {

	private func makeRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("machman-sshdir-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}

	private func entry(
		name: String = "Debian kept", user: String? = "admin",
		address: String? = "192.168.64.9",
		identity: String? = "/vms/Debian kept/ssh/id_ed25519",
		hostKey: String? = "ssh-ed25519 AAAAC3Nz host-key comment"
	) -> SSHHostConfigWriter.VMEntry {
		SSHHostConfigWriter.VMEntry(
			name: name, user: user, address: address,
			identityFilePath: identity, hostKey: hostKey)
	}

	@Test func applyWritesQuotedBlocksAndPins() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let writer = SSHHostConfigWriter(sshDir: root)
		try writer.apply(entries: [entry()])

		let managed = try String(
			contentsOf: root.appendingPathComponent("machman/config"), encoding: .utf8)
		// Names with spaces stay usable: Host and IdentityFile are quoted.
		#expect(managed.contains(#"Host "Debian kept.machman""#))
		#expect(managed.contains(#"IdentityFile "/vms/Debian kept/ssh/id_ed25519""#))
		#expect(managed.contains("HostName 192.168.64.9"))
		#expect(managed.contains("User admin"))
		#expect(managed.contains("HostKeyAlias Debian kept.machman"))
		#expect(managed.contains("StrictHostKeyChecking yes"))
		let pins = try String(
			contentsOf: root.appendingPathComponent("machman/known_hosts"), encoding: .utf8)
		#expect(pins == "Debian kept.machman ssh-ed25519 AAAAC3Nz\n")
		// The Include line landed at the top of the (created) user config.
		let user = try String(
			contentsOf: root.appendingPathComponent("config"), encoding: .utf8)
		#expect(user.hasPrefix(SSHHostConfigWriter.includeLine))
	}

	@Test func includeLineSurgeryLeavesUserContentAlone() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let userConfig = root.appendingPathComponent("config")
		try "Host work\n\tHostName work.example.com\n".write(
			to: userConfig, atomically: true, encoding: .utf8)
		let writer = SSHHostConfigWriter(sshDir: root)

		try writer.apply(entries: [entry()])
		var text = try String(contentsOf: userConfig, encoding: .utf8)
		#expect(text.hasPrefix(SSHHostConfigWriter.includeLine))
		#expect(text.contains("Host work"))
		// Idempotent: applying again adds nothing.
		try writer.apply(entries: [entry()])
		text = try String(contentsOf: userConfig, encoding: .utf8)
		#expect(text.components(separatedBy: SSHHostConfigWriter.includeLine).count == 2)

		// No entries left → the Include line goes, the user's content stays.
		try writer.apply(entries: [])
		text = try String(contentsOf: userConfig, encoding: .utf8)
		#expect(!text.contains(SSHHostConfigWriter.includeLine))
		#expect(text.contains("Host work"))
		#expect(!FileManager.default.fileExists(
			atPath: root.appendingPathComponent("machman/config").path))
	}

	@Test func regenerationKeepsLastKnownAddresses() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let writer = SSHHostConfigWriter(sshDir: root)
		try writer.apply(entries: [entry(address: "192.168.64.9")])
		// The VM stopped: discovery has no answer, the file remembers.
		try writer.apply(entries: [entry(address: nil)])
		let managed = try String(
			contentsOf: root.appendingPathComponent("machman/config"), encoding: .utf8)
		#expect(managed.contains("HostName 192.168.64.9"))
	}

	@Test func missingHostKeyFallsBackToAcceptNew() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let writer = SSHHostConfigWriter(sshDir: root)
		try writer.apply(entries: [entry(hostKey: nil)])
		let managed = try String(
			contentsOf: root.appendingPathComponent("machman/config"), encoding: .utf8)
		#expect(managed.contains("StrictHostKeyChecking accept-new"))
		#expect(!managed.contains("StrictHostKeyChecking yes"))
	}

	@Test func authorizedKeysSurgeryIsExactMatch() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let ak = root.appendingPathComponent("authorized_keys")
		try "ssh-ed25519 USERKEY personal-laptop\n".write(
			to: ak, atomically: true, encoding: .utf8)
		let writer = SSHHostConfigWriter(sshDir: root)

		try writer.setReverseKey(
			"ssh-ed25519 GUESTKEY machman-abc-reverse",
			marker: "machman-abc123def456", vmName: "Debian kept")
		var text = try String(contentsOf: ak, encoding: .utf8)
		#expect(text.contains("ssh-ed25519 USERKEY personal-laptop"))
		#expect(text.contains(
			"ssh-ed25519 GUESTKEY machman-abc-reverse machman:machman-abc123def456:Debian kept"))

		// Re-approval replaces, never duplicates.
		try writer.setReverseKey(
			"ssh-ed25519 NEWKEY fresh", marker: "machman-abc123def456", vmName: "Debian kept")
		text = try String(contentsOf: ak, encoding: .utf8)
		#expect(!text.contains("GUESTKEY"))
		#expect(text.contains("ssh-ed25519 NEWKEY fresh machman:machman-abc123def456:Debian kept"))

		// Revoke removes exactly ours; the neighbor line survives.
		try writer.setReverseKey(nil, marker: "machman-abc123def456", vmName: "Debian kept")
		text = try String(contentsOf: ak, encoding: .utf8)
		#expect(text == "ssh-ed25519 USERKEY personal-laptop\n")
	}
}
