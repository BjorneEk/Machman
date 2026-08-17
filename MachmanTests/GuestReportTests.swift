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

struct GuestReportTests {

	@Test func parserIsDefensive() {
		let report = GuestReport.parse("""
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
		let huge = String(repeating: "x", count: GuestReport.maxValueLength + 1)
		#expect(GuestReport.parse("USER=\(huge)").values["USER"] == nil)
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("machman-report-\(UUID().uuidString)")
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let big = dir.appendingPathComponent("report.env")
		try? Data(repeating: 0x41, count: GuestReport.maxBytes + 1).write(to: big)
		#expect(GuestReport.read(atPath: big.path) == nil)
	}

	@Test @MainActor func applyDrivesTheReverseStateMachine() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "sshapply")
			let vm = try VMConfig(name: "sshapply", memorySize: 1 << 30, cpuCount: 2)
			let stamp = Date(timeIntervalSince1970: 1_700_000_000)

			// First report: facts land, reverse key → pending.
			var changed = try GuestReport.parse("""
				USER=admin
				HOSTNAME=debs
				OS_ID=debian
				HOST_KEY=ssh-ed25519 AAAA host
				REVERSE_PUBKEY=ssh-ed25519 BBBB reverse
				""").apply(to: vm, stampedAt: stamp).any
			#expect(changed)
			#expect(vm.ssh?.guestUser == "admin")
			#expect(vm.ssh?.guestOS == "debian")
			#expect(vm.ssh?.reverseStateValue == .pending)
			#expect(vm.ssh?.lastReportAt == stamp)

			// Identical report again: no change, no save churn.
			changed = try GuestReport.parse("""
				USER=admin
				HOSTNAME=debs
				OS_ID=debian
				HOST_KEY=ssh-ed25519 AAAA host
				REVERSE_PUBKEY=ssh-ed25519 BBBB reverse
				""").apply(to: vm, stampedAt: Date()).any
			#expect(!changed)
			#expect(vm.ssh?.lastReportAt == stamp)

			// Approval, then a NEW reverse key: approval is revoked back to pending.
			try vm.setSSH(integrationEnabled: nil, reverseApproved: true, alias: nil)
			#expect(vm.ssh?.reverseStateValue == .approved)
			changed = try GuestReport.parse("REVERSE_PUBKEY=ssh-ed25519 CCCC fresh")
				.apply(to: vm, stampedAt: Date()).any
			#expect(changed)
			#expect(vm.ssh?.reverseStateValue == .pending)
			#expect(vm.ssh?.reversePublicKey == "ssh-ed25519 CCCC fresh")

			// Uninstall clears the guest-derived half, keeps switches + marker.
			try vm.setSSH(integrationEnabled: true, reverseApproved: nil, alias: nil)
			vm.ssh?.marker = "machman-abc"
			changed = try GuestReport.parse("UNINSTALLED=1").apply(to: vm, stampedAt: Date()).any
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
			#expect(try GuestReport.parse("""
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
				""").apply(to: vm, stampedAt: Date()).any)
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
			#expect(try GuestReport.parse("USER=gustaf\nHOSTNAME=bsd")
				.apply(to: vm, stampedAt: Date()).any)
			#expect(vm.ssh?.lastRunStatus == "partial")
			#expect(vm.ssh?.sshfsAvailable == true)

			// Uninstall does clear them: the guest no longer carries our artifacts.
			#expect(try GuestReport.parse("UNINSTALLED=1").apply(to: vm, stampedAt: Date()).any)
			#expect(vm.ssh?.sshfsAvailable == nil)
			#expect(vm.ssh?.lastRunStatus == nil)
			#expect(vm.ssh?.guestOSVersion == nil)
		}
	}

	// 1.0.7: the v3 sections land in config.setup as a whole snapshot — a clean run
	// replaces a partial one's errors — while a v2 report leaves setup untouched.
	@Test @MainActor func applyRecordsTheSetupSnapshot() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "setupapply")
			let vm = try VMConfig(name: "setupapply", memorySize: 1 << 30, cpuCount: 2)
			let stamp = Date(timeIntervalSince1970: 1_700_000_000)

			let first = try GuestReport.parse("""
				SCRIPT_VERSION=3
				STATUS=partial
				OS_ID=alpine
				OS_FAMILY=alpine
				OS_VERSION=3.20
				INIT=inittab
				TRANSPORT=virtiofs
				FEATURE_ssh=configured root
				FEATURE_console=available
				FEATURE_kernelConsole=unavailable no known bootloader tool on this guest
				CONSOLE_1=hvc0 active auto kernel
				CONSOLE_2=hvc1 configured external kernel-next
				AUTOMOUNT_1=virtiofs host-share /mnt/machman/share
				ERROR_1=console: /dev/hvc1 is not present — skipped
				""").apply(to: vm, stampedAt: stamp)
			#expect(first.setup)
			#expect(first.ssh)   // OS_ID lands in the ssh half too, v2-compatibly
			let setup = vm.setup
			#expect(setup?.installed == true)
			#expect(setup?.guestOSFamily == "alpine")
			#expect(setup?.guestInit == "inittab")
			#expect(setup?.scriptVersion == 3)
			#expect(setup?.lastRunStatus == "partial")
			#expect(setup?.lastReportAt == stamp)
			#expect(setup?.features.count == 3)
			#expect(setup?.features.first { $0.id == GuestFeature.kernelConsole }?
				.available == false)
			#expect(setup?.features.first { $0.id == GuestFeature.kernelConsole }?
				.reason == "no known bootloader tool on this guest")
			#expect(setup?.consoles.first?.login == "active-auto")
			#expect(setup?.consoles.first?.kernelConsole == true)
			#expect(setup?.consoles.first?.external == nil)
			#expect(setup?.consoles.last?.login == "configured")
			#expect(setup?.consoles.last?.external == true)
			#expect(setup?.consoles.last?.kernelConsolePending == true)
			#expect(setup?.consoles.last?.kernelConsole == nil)
			#expect(setup?.automounts
				== [GuestAutomountInfo(
					kind: "virtiofs", target: "host-share", path: "/mnt/machman/share")])
			#expect(setup?.errors.first?.step == "console")

			// A clean re-run REPLACES the snapshot: the error is gone, not accumulated.
			#expect(try GuestReport.parse("""
				SCRIPT_VERSION=3
				STATUS=ok
				FEATURE_ssh=configured root
				CONSOLE_1=hvc0 active auto kernel
				CONSOLE_2=hvc1 active
				""").apply(to: vm, stampedAt: Date()).setup)
			#expect(vm.setup?.lastRunStatus == "ok")
			#expect(vm.setup?.errors.isEmpty == true)
			#expect(vm.setup?.automounts.isEmpty == true)
			#expect(vm.setup?.consoles.last?.login == "active")

			// A v2 report (no sections, script < 3) leaves the setup half alone.
			#expect(!(try GuestReport.parse("SCRIPT_VERSION=2\nUSER=root")
				.apply(to: vm, stampedAt: Date()).setup))
			#expect(vm.setup?.lastRunStatus == "ok")

			// Uninstall clears the learned snapshot but keeps the OS facts.
			#expect(try GuestReport.parse("UNINSTALLED=1")
				.apply(to: vm, stampedAt: Date()).setup)
			#expect(vm.setup?.installed == false)
			#expect(vm.setup?.features.isEmpty == true)
			#expect(vm.setup?.guestOS == "alpine")
		}
	}

	// The reported host key is pinned where the in-app session tabs look for it — under
	// the VM's alias, so the app never has to touch the user's own known_hosts.
	@Test @MainActor func reportedHostKeyIsPinnedUnderTheAlias() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "sshpin")
			let vm = try VMConfig(name: "sshpin", memorySize: 1 << 30, cpuCount: 2)
			let fm = FileManager.default
			try fm.createDirectory(
				atPath: vm.configFilePath(file: "ssh"), withIntermediateDirectories: true)
			let path = SSHSetupInstaller.knownHostsPath(for: vm)

			#expect(try GuestReport.parse("USER=admin\nHOST_KEY=ssh-ed25519 AAAA guest@host")
				.apply(to: vm, stampedAt: Date()).any)
			#expect(try String(contentsOfFile: path, encoding: .utf8)
				== "sshpin.machman ssh-ed25519 AAAA\n")
			#expect((try fm.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)

			// Renaming the alias re-keys the pin then and there — a session verifying
			// against the old name would fail with "no host key is known".
			try vm.setSSH(integrationEnabled: nil, reverseApproved: nil, alias: "dev")
			#expect(try String(contentsOfFile: path, encoding: .utf8)
				== "dev ssh-ed25519 AAAA\n")

			// Uninstalled: no key, no stale pin.
			#expect(try GuestReport.parse("UNINSTALLED=1").apply(to: vm, stampedAt: Date()).any)
			#expect(!fm.fileExists(atPath: path))
		}
	}
}
