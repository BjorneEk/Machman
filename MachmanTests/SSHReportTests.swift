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
			try vm.setSSH(integrationEnabled: nil, reverseApproved: true, alias: nil)
			#expect(vm.ssh?.reverseStateValue == .approved)
			changed = try SSHReport.parse("REVERSE_PUBKEY=ssh-ed25519 CCCC fresh")
				.apply(to: vm, stampedAt: Date())
			#expect(changed)
			#expect(vm.ssh?.reverseStateValue == .pending)
			#expect(vm.ssh?.reversePublicKey == "ssh-ed25519 CCCC fresh")

			// Uninstall clears the guest-derived half, keeps switches + marker.
			try vm.setSSH(integrationEnabled: true, reverseApproved: nil, alias: nil)
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

	// 1.0.6 keys: what the run achieved, how it got there, what the guest can do.
	@Test @MainActor func applyRecordsRunOutcomeAndCapabilities() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "sshv2")
			let vm = try VMConfig(name: "sshv2", memorySize: 1 << 30, cpuCount: 2)
			#expect(try SSHReport.parse("""
				SCRIPT_VERSION=2
				USER=gustaf
				OS_ID=freebsd
				OS_VERSION=15.1
				IP=192.168.64.5
				STATUS=partial
				NOTE=sshfs is installed but user mounts are off
				FAILED_STEPS=mount-setup
				TRANSPORT=sshfs
				SSHFS=1
				SSHFS_VERSION=3.7.3
				SSHFS_MOUNT_OK=0
				SSHFS_MOUNTROOT=/mnt/machman
				""").apply(to: vm, stampedAt: Date()))
			#expect(vm.ssh?.scriptVersion == 2)
			#expect(vm.ssh?.guestOSVersion == "15.1")
			#expect(vm.ssh?.lastAddress == "192.168.64.5")
			#expect(vm.ssh?.lastRunStatus == "partial")
			#expect(vm.ssh?.lastRunNote == "sshfs is installed but user mounts are off")
			#expect(vm.ssh?.lastTransport == "sshfs")
			#expect(vm.ssh?.sshfsAvailable == true)
			#expect(vm.ssh?.sshfsMountReady == false)
			#expect(vm.ssh?.sshfsMountRoot == "/mnt/machman")

			// A v1 report (no STATUS/SSHFS keys) is an older script, not a failure — it
			// must not silently clear what a v2 run recorded.
			#expect(try SSHReport.parse("USER=gustaf\nHOSTNAME=bsd")
				.apply(to: vm, stampedAt: Date()))
			#expect(vm.ssh?.lastRunStatus == "partial")
			#expect(vm.ssh?.sshfsAvailable == true)

			// Uninstall does clear them: the guest no longer carries our artifacts.
			#expect(try SSHReport.parse("UNINSTALLED=1").apply(to: vm, stampedAt: Date()))
			#expect(vm.ssh?.sshfsAvailable == nil)
			#expect(vm.ssh?.lastRunStatus == nil)
			#expect(vm.ssh?.guestOSVersion == nil)
		}
	}
}
