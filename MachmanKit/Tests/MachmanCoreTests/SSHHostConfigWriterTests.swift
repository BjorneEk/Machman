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
import MachmanAPI
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

	// C31: the backstop skips a second block whose alias differs only in case — written, it
	// would share the first one's host-key pin.
	@Test("C31: ~/.ssh gets one block for aliases that differ only in case")
	func aCaseVariantAliasIsSkipped() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		try SSHHostConfigWriter(sshDir: root).apply(entries: [
			entry(name: "alpha", alias: "Dev.machman", address: "192.168.64.9"),
			entry(name: "beta", alias: "dev.machman", address: "192.168.64.10"),
		])
		let managed = try String(
			contentsOf: root.appendingPathComponent("machman/config"), encoding: .utf8)
		#expect(managed.contains("HostName 192.168.64.9"))
		#expect(!managed.contains("192.168.64.10"))
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

	// S22, the writer half: state stored before the report was shape-checked (validate at
	// entry, never at load) still never reaches the file in a form that breaks ssh.
	@Test func hostileValuesNeverReachTheFile() async throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let writer = SSHHostConfigWriter(sshDir: root)
		let managed = root.appendingPathComponent("machman/config")

		try writer.apply(entries: [entry(user: "a b")])
		var text = try String(contentsOf: managed, encoding: .utf8)
		#expect(!text.contains("\tUser "))
		#expect(text.contains("HostName 192.168.64.9"))

		try writer.apply(entries: [entry(hostKey: "@revoked x")])
		text = try String(contentsOf: managed, encoding: .utf8)
		#expect(text.contains("StrictHostKeyChecking accept-new"))
		#expect(try String(contentsOf: root.appendingPathComponent("machman/known_hosts"),
			encoding: .utf8).isEmpty)

		try writer.apply(entries: [])
		try writer.apply(entries: [entry(address: "x y")])
		#expect(!FileManager.default.fileExists(atPath: managed.path))

		// A previous file that carries a hostile HostName is no fallback either.
		try FileManager.default.createDirectory(
			at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
		try "Host \"Debian-kept.machman\"\n\tHostName evil host\n".write(
			to: managed, atomically: true, encoding: .utf8)
		try writer.apply(entries: [entry(address: nil)])
		#expect(!FileManager.default.fileExists(atPath: managed.path))

		if OpenSSHConfigCheck.available {
			try writer.apply(entries: [entry(user: "a b"), entry(name: "other", user: "$(x)")])
			let other = try await OpenSSHConfigCheck.resolve(
				config: managed, host: "unrelated.invalid")
			#expect(other.status == 0, "\(other.output)")
		}

		let ak = root.appendingPathComponent("authorized_keys")
		try "ssh-ed25519 USERKEY mine\n".write(to: ak, atomically: true, encoding: .utf8)
		#expect(throws: MachmanError.self) {
			try writer.setReverseKey(
				"command=\"x\" ssh-ed25519 AAAA", marker: "machman-abc", vmName: "v")
		}
		#expect(throws: MachmanError.self) {
			try writer.setReverseKey(
				"ssh-ed25519 AAAA\nssh-ed25519 BBBB", marker: "machman-abc", vmName: "v")
		}
		#expect(try String(contentsOf: ak, encoding: .utf8) == "ssh-ed25519 USERKEY mine\n")
	}

	// C17: a VM named dev"x put IdentityFile "/vms/dev"x/…" into the file, and OpenSSH
	// refused it — for every host. Quotes and backslashes are escaped, % is doubled (the
	// path options expand %-tokens), and a line break can't be carried at all.
	@Test(.enabled(if: OpenSSHConfigCheck.available))
	func pathsWithQuotesAndPercentSignsStayParseable() async throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let writer = SSHHostConfigWriter(sshDir: root)
		try writer.apply(entries: [
			entry(name: "dev\"x 50%", identity: "/vms/dev\"x 50%/ssh/id_ed25519")])
		let managed = root.appendingPathComponent("machman/config")
		let text = try String(contentsOf: managed, encoding: .utf8)
		#expect(text.contains(#"IdentityFile "/vms/dev\"x 50%%/ssh/id_ed25519""#))

		let vm = try await OpenSSHConfigCheck.resolve(config: managed, host: "dev-x-50.machman")
		#expect(vm.status == 0, "\(vm.output)")
		#expect(vm.output.contains(#"identityfile /vms/dev"x 50%%/ssh/id_ed25519"#))
		let other = try await OpenSSHConfigCheck.resolve(config: managed, host: "unrelated.invalid")
		#expect(other.status == 0, "\(other.output)")
	}

	// Review F2: ssh expands ${VAR} in IdentityFile with no escape — the entry is left out.
	@Test func aPathHoldingADollarBraceDropsTheEntry() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		try SSHHostConfigWriter(sshDir: root).apply(
			entries: [entry(name: "x${y}", identity: "/vms/x${y}/ssh/id_ed25519")])
		#expect(!FileManager.default.fileExists(
			atPath: root.appendingPathComponent("machman/config").path))
	}

	@Test func aPathWithALineBreakDropsTheEntry() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let writer = SSHHostConfigWriter(sshDir: root)
		try writer.apply(entries: [entry(name: "a\nb", identity: "/vms/a\nb/id")])
		#expect(!FileManager.default.fileExists(
			atPath: root.appendingPathComponent("machman/config").path))

		try writer.setReverseKey("ssh-ed25519 AAAA g", marker: "machman-abc", vmName: "a\nb")
		#expect(try String(contentsOf: root.appendingPathComponent("authorized_keys"),
			encoding: .utf8) == "ssh-ed25519 AAAA g machman:machman-abc:a-b\n")
	}

	// S23: dotfile managers keep ~/.ssh/config and authorized_keys as links. A write to the
	// link's path replaced the link with a plain file, detaching the user's managed copy.
	@Test func aSymlinkedUserConfigIsWrittenThrough() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let fm = FileManager.default
		let dotfiles = root.appendingPathComponent("dotfiles")
		try fm.createDirectory(at: dotfiles, withIntermediateDirectories: true)
		let target = dotfiles.appendingPathComponent("config")
		try "Host work\n".write(to: target, atomically: true, encoding: .utf8)
		try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
		let link = root.appendingPathComponent("config")
		try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "dotfiles/config")

		try SSHHostConfigWriter(sshDir: root).apply(entries: [entry()])
		#expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "dotfiles/config")
		let text = try String(contentsOf: target, encoding: .utf8)
		#expect(text.hasPrefix(SSHHostConfigWriter.includeLine))
		#expect(text.contains("Host work"))
		let mode = try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
		#expect(mode?.intValue == 0o644)
	}

	@Test func aSymlinkedAuthorizedKeysIsWrittenThrough() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let fm = FileManager.default
		let target = root.appendingPathComponent("keys-real")
		try "ssh-ed25519 USERKEY mine\n".write(to: target, atomically: true, encoding: .utf8)
		let link = root.appendingPathComponent("authorized_keys")
		try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

		try SSHHostConfigWriter(sshDir: root).setReverseKey(
			"ssh-ed25519 AAAA g", marker: "machman-abc", vmName: "v")
		#expect(try fm.destinationOfSymbolicLink(atPath: link.path) == target.path)
		#expect(try String(contentsOf: target, encoding: .utf8)
			== "ssh-ed25519 USERKEY mine\nssh-ed25519 AAAA g machman:machman-abc:v\n")
	}

	@Test func aDanglingOrUnwritableLinkIsRefusedNotReplaced() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let fm = FileManager.default
		let writer = SSHHostConfigWriter(sshDir: root)
		let link = root.appendingPathComponent("config")

		// A broken link: refused, left as it is.
		try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "missing/config")
		#expect(throws: MachmanError.self) { try writer.apply(entries: [entry()]) }
		#expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "missing/config")

		// A link into a directory that can't be written (the nix store shape).
		try fm.removeItem(at: link)
		let store = root.appendingPathComponent("store")
		try fm.createDirectory(at: store, withIntermediateDirectories: true)
		let target = store.appendingPathComponent("config")
		try "Host work\n".write(to: target, atomically: true, encoding: .utf8)
		try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.path)
		defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.path) }
		try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
		#expect(throws: MachmanError.self) { try writer.apply(entries: [entry()]) }
		#expect(try fm.destinationOfSymbolicLink(atPath: link.path) == target.path)
		#expect(try String(contentsOf: target, encoding: .utf8) == "Host work\n")
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

	// MARK: - C20: the user's files are bytes, and an unreadable one is never "empty"

	// "café" and "göran" in Latin-1: 0xE9 and 0xF6 are not UTF-8. Read as UTF-8 text these
	// files counted as empty, and the next write replaced them with Machman's line alone.
	private let latin1Config = Data("Host work\n\tHostName work.example # caf".utf8)
		+ Data([0xE9]) + Data("\n".utf8)
	private let latin1Keys = Data("ssh-ed25519 USERKEY g".utf8) + Data([0xF6])
		+ Data("ran@laptop\n".utf8)

	@Test func aLatin1ConfigKeepsEveryByte() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let userConfig = root.appendingPathComponent("config")
		try latin1Config.write(to: userConfig)
		let writer = SSHHostConfigWriter(sshDir: root)

		try writer.apply(entries: [entry()])
		#expect(try Data(contentsOf: userConfig)
			== Data((SSHHostConfigWriter.includeLine + "\n").utf8) + latin1Config)

		try writer.apply(entries: [])
		#expect(try Data(contentsOf: userConfig) == latin1Config)
	}

	@Test func aLatin1AuthorizedKeysKeepsTheUsersLine() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let ak = root.appendingPathComponent("authorized_keys")
		try latin1Keys.write(to: ak)
		let writer = SSHHostConfigWriter(sshDir: root)

		try writer.setReverseKey("ssh-ed25519 GUESTKEY g", marker: "machman-abc", vmName: "dev")
		#expect(try Data(contentsOf: ak)
			== latin1Keys + Data("ssh-ed25519 GUESTKEY g machman:machman-abc:dev\n".utf8))

		try writer.setReverseKey(nil, marker: "machman-abc", vmName: "dev")
		#expect(try Data(contentsOf: ak) == latin1Keys)
	}

	@Test func anUnreadableFileIsRefusedAndLeftAlone() throws {
		let root = try makeRoot()
		let fm = FileManager.default
		let userConfig = root.appendingPathComponent("config")
		let ak = root.appendingPathComponent("authorized_keys")
		try latin1Config.write(to: userConfig)
		try latin1Keys.write(to: ak)
		for file in [userConfig, ak] {
			try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
		}
		defer {
			for file in [userConfig, ak] {
				try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
			}
			try? fm.removeItem(at: root)
		}
		let writer = SSHHostConfigWriter(sshDir: root)

		let attempts: [() throws -> Void] = [
			{ try writer.apply(entries: [entry()]) },
			{ try writer.setReverseKey("ssh-ed25519 G g", marker: "machman-abc", vmName: "v") },
			{ try writer.setReverseKey(nil, marker: "machman-abc", vmName: "v") },
		]
		for attempt in attempts {
			do {
				try attempt()
				Issue.record("expected an unreadable file to be refused")
			} catch let error as MachmanError {
				#expect(error.code == .ioFailure)
				#expect(error.message.hasPrefix("Couldn’t read "))
			}
		}
		for file in [userConfig, ak] {
			try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
		}
		#expect(try Data(contentsOf: userConfig) == latin1Config)
		#expect(try Data(contentsOf: ak) == latin1Keys)
	}

	@Test func aRemovalWithNothingOfOursLeavesTheFileAlone() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let fm = FileManager.default
		let ak = root.appendingPathComponent("authorized_keys")
		let original = Data("ssh-ed25519 USERKEY mine\n\n\n".utf8)
		try original.write(to: ak)
		let before = try fm.attributesOfItem(atPath: ak.path)[.systemFileNumber] as? NSNumber

		try SSHHostConfigWriter(sshDir: root).setReverseKey(
			nil, marker: "machman-abc", vmName: "dev")
		#expect(try Data(contentsOf: ak) == original)
		// Not even rewritten: an atomic write would have replaced the file.
		#expect(try fm.attributesOfItem(atPath: ak.path)[.systemFileNumber] as? NSNumber
			== before)
	}
}
