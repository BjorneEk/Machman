//
//  GuestSetupLabSSHDTests.swift
//  MachmanCoreTests
//
//  TB6: a guest reaches "the Mac" as its default gateway on port 22 and pins the Mac's sshd
//  host key (host_machine_key.pub) for 'ssh mac' and its sshfs mounts. The lab routes that
//  address to its own sshd, so under a lab sshd (MACHMAN_LAB_SSHD_HOSTKEY) the payload pins
//  the lab's key instead. Everything else in the payload, machman.env included, is today's.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

struct GuestSetupLabSSHDTests {
	private static let suite = "com.gustaffranzen.Machman.test-abc1"
	private static let labKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIlabkey lab-sshd\n"

	private static func scratchFile(_ text: String?) throws -> String {
		let path = TestEnvironment.scratch + "hostkey-\(UUID().uuidString).pub"
		if let text { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) }
		return path
	}

	private static func lab(hostKey: String?) throws -> LabEnvironment {
		try #require(LabEnvironment(
			suiteID: suite,
			environment: hostKey.map { ["MACHMAN_LAB_SSHD_HOSTKEY": $0] } ?? [:],
			debugBuild: true))
	}

	// A VM whose host→guest keypair already exists, so the payload never runs ssh-keygen.
	private static func makeVM(_ name: String) throws -> VMConfig {
		try VMConfig.createNewVMDirectory(name: name)
		let vm = try VMConfig(name: name, memorySize: 1 << 30, cpuCount: 2)
		let marker = try SSHSetupInstaller.marker(for: vm)
		let ssh = vm.localURL(file: "ssh")
		try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
		try Data("private".utf8).write(to: ssh.appendingPathComponent("id_ed25519"))
		try Data("ssh-ed25519 AAAAvm \(marker) \(name)\n".utf8)
			.write(to: ssh.appendingPathComponent("id_ed25519.pub"))
		return vm
	}

	@Test("Q18: without a lab sshd the guest pins this Mac's host key as today (TB6)")
	func withoutALabSSHDTheGuestPinsThisMac() throws {
		let mac = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAImac root@mac\n"
		let system = try Self.scratchFile(mac)
		for suite in ["com.gustaffranzen.Machman.dev", "com.gustaffranzen.Machman"] {
			let lab = LabEnvironment(
				suiteID: suite, environment: ["MACHMAN_LAB_SSHD_HOSTKEY": system + ".lab"],
				debugBuild: true)
			#expect(lab == nil)
			#expect(GuestSetupInstaller.machineHostKey(lab: lab, systemKeyPath: system)
				== Data(mac.utf8))
		}
		// A test suite with no lab sshd: today's pin too.
		#expect(GuestSetupInstaller.machineHostKey(
			lab: try Self.lab(hostKey: nil), systemKeyPath: system) == Data(mac.utf8))
		// No system key (sshd never set up): no pin, as today.
		#expect(GuestSetupInstaller.machineHostKey(
			lab: nil, systemKeyPath: try Self.scratchFile(nil)) == nil)
		// The real default reads this Mac's key, when it has one.
		let real = FileManager.default.contents(atPath: "/etc/ssh/ssh_host_ed25519_key.pub")
		#expect(GuestSetupInstaller.machineHostKey(lab: nil) == real)
	}

	@Test("Q18: a lab sshd replaces the Mac's host-key pin (TB6)")
	func aLabSSHDReplacesTheMacsPin() throws {
		let lab = try Self.lab(hostKey: try Self.scratchFile(Self.labKey))
		let system = try Self.scratchFile("ssh-ed25519 AAAAmac root@mac\n")
		#expect(GuestSetupInstaller.machineHostKey(lab: lab, systemKeyPath: system)
			== Data(Self.labKey.utf8))
		try VMTestDir.withRedirectedDir {
			let vm = try Self.makeVM("pinned")
			let files = try GuestSetupInstaller.extraFiles(for: vm, lab: lab)
			#expect(files["host_machine_key.pub"] == Data(Self.labKey.utf8))
			#expect(files["host_key.pub"] != nil)
			// machman.env is not the seam: no lab key reaches it.
			let environment = try GuestSetupInstaller.environment(for: vm)
			#expect(!environment.keys.contains { $0.contains("LAB") })
		}
	}

	@Test("Q18: a lab sshd without a readable host key ships no pin (TB6)")
	func aLabSSHDWithoutAReadableKeyShipsNoPin() throws {
		let system = try Self.scratchFile("ssh-ed25519 AAAAmac root@mac\n")
		for missing in [try Self.scratchFile(nil), try Self.scratchFile(" \n")] {
			let lab = try Self.lab(hostKey: missing)
			#expect(GuestSetupInstaller.machineHostKey(lab: lab, systemKeyPath: system) == nil)
		}
		try VMTestDir.withRedirectedDir {
			let vm = try Self.makeVM("unpinned")
			let lab = try Self.lab(hostKey: try Self.scratchFile(nil))
			let files = try GuestSetupInstaller.extraFiles(for: vm, lab: lab)
			// Listed with no data: the writer removes any pin an earlier payload left.
			#expect(files.keys.contains("host_machine_key.pub"))
			#expect(files["host_machine_key.pub"] == .some(nil))
		}
	}
}
