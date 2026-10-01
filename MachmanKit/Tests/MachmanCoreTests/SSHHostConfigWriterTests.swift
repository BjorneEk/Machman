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
import MachmanTestSupport
@testable import MachmanCore

struct SSHHostConfigWriterTests {

	private func makeRoot() throws -> URL {
		let root = TestEnvironment.scratchURL
			.appendingPathComponent("machman-sshdir-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}

	private func entry(
		name: String = "Debian kept", alias: String? = nil, user: String? = "admin",
		address: String? = "192.168.64.9",
		identity: String? = "/vms/Debian kept/ssh/id_ed25519",
		hostKey: String? = "ssh-ed25519 AAAAC3Nz host-key comment"
	) -> SSHHostConfigWriter.VMEntry {
		SSHHostConfigWriter.VMEntry(
			name: name, alias: alias ?? SSHHostConfigWriter.defaultAlias(for: name),
			user: user, address: address,
			identityFilePath: identity, hostKey: hostKey)
	}

	@Test func applyWritesQuotedBlocksAndPins() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let writer = SSHHostConfigWriter(sshDir: root)
		try writer.apply(entries: [entry()])

		let managed = try String(
			contentsOf: root.appendingPathComponent("machman/config"), encoding: .utf8)
		// A spaced VM name gets an alias in the alias charset (C13); its paths stay quoted.
		#expect(managed.contains(#"Host "Debian-kept.machman""#))
		#expect(managed.contains(#"IdentityFile "/vms/Debian kept/ssh/id_ed25519""#))
		#expect(managed.contains("HostName 192.168.64.9"))
		#expect(managed.contains("User admin"))
		#expect(managed.contains("HostKeyAlias Debian-kept.machman"))
		#expect(managed.contains("StrictHostKeyChecking yes"))
		let pins = try String(
			contentsOf: root.appendingPathComponent("machman/known_hosts"), encoding: .utf8)
		#expect(pins == "Debian-kept.machman ssh-ed25519 AAAAC3Nz\n")
		// The Include line landed at the top of the (created) user config.
		let user = try String(
			contentsOf: root.appendingPathComponent("config"), encoding: .utf8)
		#expect(user.hasPrefix(SSHHostConfigWriter.includeLine))
	}

	// A VM can be named something else in ~/.ssh; every place the alias appears follows it.
	@Test func customAliasNamesTheBlockAndThePin() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let writer = SSHHostConfigWriter(sshDir: root)
		try writer.apply(entries: [entry(name: "Debian kept", alias: "dev")])

		let managed = try String(
			contentsOf: root.appendingPathComponent("machman/config"), encoding: .utf8)
		#expect(managed.contains(#"Host "dev""#))
		#expect(managed.contains("HostKeyAlias dev"))
		#expect(!managed.contains("Debian-kept.machman"))
		let pins = try String(
			contentsOf: root.appendingPathComponent("machman/known_hosts"), encoding: .utf8)
		#expect(pins.hasPrefix("dev ssh-ed25519"))

		// Regeneration keeps a known address for an alias it already wrote…
		try writer.apply(entries: [entry(name: "Debian kept", alias: "dev", address: nil)])
		#expect(try String(contentsOf: root.appendingPathComponent("machman/config"),
			encoding: .utf8).contains("HostName 192.168.64.9"))
		// …but a RENAMED alias has no history: with no address to write, the entry drops
		// out entirely. That is exactly why the daemon passes the guest's last reported
		// address instead of relying on this file.
		try writer.apply(entries: [entry(name: "Debian kept", alias: "other", address: nil)])
		let after = (try? String(contentsOf: root.appendingPathComponent("machman/config"),
			encoding: .utf8)) ?? ""
		#expect(!after.contains(#"Host "other""#))
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

	// An alias with no address would fail with a DNS-flavored error — no block (and no
	// Include line) until discovery has ever answered.
	@Test func unaddressedEntriesWriteNoBlocks() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let writer = SSHHostConfigWriter(sshDir: root)
		try writer.apply(entries: [entry(address: nil)])
		#expect(!FileManager.default.fileExists(
			atPath: root.appendingPathComponent("machman/config").path))
		let userConfig = root.appendingPathComponent("config")
		let text = (try? String(contentsOf: userConfig, encoding: .utf8)) ?? ""
		#expect(!text.contains(SSHHostConfigWriter.includeLine))
	}

	// D10: when the last SSH VM goes, the managed dir goes too — nothing of Machman's
	// outlives its content in ~/.ssh (the surrounding .ssh dir is not ours to touch).
	@Test func lastEntryLeavingRemovesTheManagedDir() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let writer = SSHHostConfigWriter(sshDir: root)
		try writer.apply(entries: [entry()])
		let managedDir = root.appendingPathComponent("machman")
		#expect(FileManager.default.fileExists(atPath: managedDir.path))

		try writer.apply(entries: [])
		#expect(!FileManager.default.fileExists(atPath: managedDir.path))
		#expect(FileManager.default.fileExists(atPath: root.path))
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
