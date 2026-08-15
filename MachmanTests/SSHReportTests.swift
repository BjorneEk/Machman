//
//  SSHReportTests.swift
//  MachmanTests
//
//  The guest report parser (defensive: the drop-box is guest-writable) and the state
//  transitions apply() drives — pending promotion, new-key re-approval, uninstall clear.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct SSHReportTests {

	@Test func parserIsDefensive() {
		let report = SSHReport.parse("""
			# a comment
			USER=admin
			garbage line without an equals sign
			NOT_A_KEY=ignored
			HOSTNAME=debs\r
			IP = 192.168.64.5
			HOST_KEY=ssh-ed25519 AAAA guest=host
			USER=root2
			""")
		#expect(report.values["USER"] == "root2")            // last occurrence wins
		#expect(report.values["HOSTNAME"] == "debs")         // CRLF tolerated
		#expect(report.values["NOT_A_KEY"] == nil)           // whitelist
		#expect(report.values["IP "] == nil)                 // "IP " is not a key
		#expect(report.values["HOST_KEY"] == "ssh-ed25519 AAAA guest=host")   // = in value
	}

	@Test func oversizedValuesAndFilesAreRefused() {
		let huge = String(repeating: "x", count: SSHReport.maxValueLength + 1)
		#expect(SSHReport.parse("USER=\(huge)").values["USER"] == nil)
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("machman-report-\(UUID().uuidString)")
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let big = dir.appendingPathComponent("report.env")
		try? Data(repeating: 0x41, count: SSHReport.maxBytes + 1).write(to: big)
		#expect(SSHReport.read(atPath: big.path) == nil)
	}

	@Test @MainActor func applyDrivesTheReverseStateMachine() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "sshapply")
			let vm = try VMConfig(name: "sshapply", memorySize: 1 << 30, cpuCount: 2)
			let stamp = Date(timeIntervalSince1970: 1_700_000_000)

			// First report: facts land, reverse key → pending.
			var changed = try SSHReport.parse("""
				USER=admin
				HOSTNAME=debs
				OS_ID=debian
				HOST_KEY=ssh-ed25519 AAAA host
				REVERSE_PUBKEY=ssh-ed25519 BBBB reverse
				""").apply(to: vm, stampedAt: stamp)
			#expect(changed)
			#expect(vm.ssh?.guestUser == "admin")
			#expect(vm.ssh?.guestOS == "debian")
			#expect(vm.ssh?.reverseStateValue == .pending)
			#expect(vm.ssh?.lastReportAt == stamp)

			// Identical report again: no change, no save churn.
			changed = try SSHReport.parse("""
				USER=admin
				HOSTNAME=debs
				OS_ID=debian
				HOST_KEY=ssh-ed25519 AAAA host
				REVERSE_PUBKEY=ssh-ed25519 BBBB reverse
				""").apply(to: vm, stampedAt: Date())
			#expect(!changed)
			#expect(vm.ssh?.lastReportAt == stamp)

			// Approval, then a NEW reverse key: approval is revoked back to pending.
			try vm.setSSH(integrationEnabled: nil, reverseApproved: true)
			#expect(vm.ssh?.reverseStateValue == .approved)
			changed = try SSHReport.parse("REVERSE_PUBKEY=ssh-ed25519 CCCC fresh")
				.apply(to: vm, stampedAt: Date())
			#expect(changed)
			#expect(vm.ssh?.reverseStateValue == .pending)
			#expect(vm.ssh?.reversePublicKey == "ssh-ed25519 CCCC fresh")

			// Uninstall clears the guest-derived half, keeps switches + marker.
			try vm.setSSH(integrationEnabled: true, reverseApproved: nil)
			vm.ssh?.marker = "machman-abc"
			changed = try SSHReport.parse("UNINSTALLED=1").apply(to: vm, stampedAt: Date())
			#expect(changed)
			#expect(vm.ssh?.guestUser == nil)
			#expect(vm.ssh?.guestHostKey == nil)
			#expect(vm.ssh?.reversePublicKey == nil)
			#expect(vm.ssh?.reverseStateValue == SSHInfo.ReverseState.none)
			#expect(vm.ssh?.integrationEnabled == true)
			#expect(vm.ssh?.marker == "machman-abc")
		}
	}
}
