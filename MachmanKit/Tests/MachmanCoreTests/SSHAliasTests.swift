//
//  SSHAliasTests.swift
//  MachmanCoreTests
//
//  C13: a VM named with a space ("dev copy" — every Duplicate makes one) used to put
//  `HostKeyAlias dev copy.machman` into the managed ~/.ssh file, and OpenSSH then refused
//  to run at all, for every host. The default alias is now mapped into the alias charset,
//  the writer never emits an alias outside it, and every start re-pins under the alias the
//  VM answers to now.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

@MainActor
struct SSHAliasTests {

	private func makeRoot() throws -> URL {
		let root = TestEnvironment.scratchURL
			.appendingPathComponent("machman-sshalias-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}

	private func entry(
		_ name: String, alias: String? = nil, address: String? = "192.168.64.9"
	) -> SSHHostConfigWriter.VMEntry {
		SSHHostConfigWriter.VMEntry(
			name: name, alias: alias ?? SSHHostConfigWriter.defaultAlias(for: name),
			user: "admin", address: address,
			identityFilePath: "/vms/\(name)/ssh/id_ed25519",
			hostKey: "ssh-ed25519 AAAAC3Nz host")
	}

	@Test(.enabled(if: OpenSSHConfigCheck.available))
	func opensshAcceptsTheManagedConfig() async throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		try SSHHostConfigWriter(sshDir: root).apply(entries: [entry("dev copy")])
		let managed = root.appendingPathComponent("machman/config")

		let vm = try await OpenSSHConfigCheck.resolve(config: managed, host: "dev-copy.machman")
		#expect(vm.status == 0, "\(vm.output)")
		#expect(vm.output.lowercased().contains("hostkeyalias dev-copy.machman"))
		#expect(vm.output.lowercased().contains("hostname 192.168.64.9"))
		// The real damage was to everything else: an unrelated host must still resolve.
		let other = try await OpenSSHConfigCheck.resolve(config: managed, host: "unrelated.invalid")
		#expect(other.status == 0, "\(other.output)")
	}

	@Test func aRawAliasFallsBackAndACollisionKeepsTheFirstVM() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let writer = SSHHostConfigWriter(sshDir: root)
		let managed = root.appendingPathComponent("machman/config")

		// An older vmhost still serving the raw default.
		try writer.apply(entries: [entry("dev copy", alias: "dev copy.machman")])
		var text = try String(contentsOf: managed, encoding: .utf8)
		#expect(text.contains(#"Host "dev-copy.machman""#))
		#expect(!text.contains("dev copy.machman"))

		// Two VMs landing on one alias: one block, the first VM's.
		try writer.apply(entries: [
			entry("dev copy", address: "192.168.64.9"),
			entry("dev-copy", address: "192.168.64.10"),
		])
		text = try String(contentsOf: managed, encoding: .utf8)
		#expect(text.components(separatedBy: #"Host "dev-copy.machman""#).count == 2)
		#expect(text.contains("HostName 192.168.64.9"))
		#expect(!text.contains("HostName 192.168.64.10"))
	}

	@Test func aSpacedNameGetsASanitizedDefaultAlias() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "dev copy")
			let vm = try VMConfig(name: "dev copy", memorySize: 1 << 30, cpuCount: 2)
			#expect(vm.effectiveSSHAlias == "dev-copy.machman")
		}
	}

	@Test func everyStartRepinsUnderTheCurrentAlias() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "pin copy")
			let vm = try VMConfig(name: "pin copy", memorySize: 1 << 30, cpuCount: 2)
			try FileManager.default.createDirectory(
				atPath: vm.configFilePath(file: "ssh"), withIntermediateDirectories: true)
			var ssh = SSHConfig()
			ssh.guestHostKey = "ssh-ed25519 AAAA host"
			vm.ssh = ssh
			var setup = GuestSetupConfig()
			setup.installed = true
			vm.setup = setup
			try vm.saveVMConfig()
			#expect(!vm.servesSetupPayload)
			// The pin an older build wrote, under the raw spaced alias.
			let pin = SSHSetupInstaller.knownHostsPath(for: vm)
			try "pin copy.machman ssh-ed25519 AAAA\n".write(
				toFile: pin, atomically: true, encoding: .utf8)

			try GuestSetupInstaller.ensurePayloadDirectories(for: vm)
			#expect(try String(contentsOfFile: pin, encoding: .utf8)
				== "pin-copy.machman ssh-ed25519 AAAA\n")
		}
	}
}
