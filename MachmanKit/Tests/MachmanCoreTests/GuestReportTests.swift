//
//  GuestReportTests.swift
//  MachmanCoreTests
//
//  The guest report parser (defensive: the drop-box is guest-writable) and the state
//  transitions apply() drives — pending promotion, new-key re-approval, uninstall clear.
//

import Testing
import Foundation
import MachmanTestSupport
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

	// W2: keys the script writes that no host code reads are not kept; the keys apply()
	// reads still parse and apply from the same report.
	@Test @MainActor func unreadReportKeysAreDroppedAndTheRestApplies() throws {
		let report = GuestReport.parse("""
			SCRIPT_VERSION=5
			STATUS=ok
			FAILED_STEPS=sshd
			OS_ID=debian
			HOSTNAME=deb
			IP=192.168.64.7
			GATEWAY=192.168.64.1
			SSHD=1
			USER=admin
			HOME=/home/admin
			TWO_WAY=1
			SSHFS=1
			SSHFS_VERSION=3.7.3
			KERNEL_CONSOLE=hvc0
			KERNEL_CONSOLE_METHOD=grubby
			""")
		for key in [
			"HOME", "GATEWAY", "TWO_WAY", "SSHD", "SSHFS_VERSION", "FAILED_STEPS",
			"KERNEL_CONSOLE", "KERNEL_CONSOLE_METHOD",
		] {
			#expect(report.values[key] == nil, "\(key) is kept but nothing reads it")
		}
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "unread-keys")
			let vm = try VMConfig(name: "unread-keys", memorySize: 1 << 30, cpuCount: 2)
			#expect(try report.apply(to: vm, stampedAt: Date()).any)
			#expect(vm.ssh?.guestUser == "admin")
			#expect(vm.ssh?.guestHostname == "deb")
			#expect(vm.ssh?.lastAddress == "192.168.64.7")
			#expect(vm.ssh?.sshfsAvailable == true)
			#expect(vm.setup?.lastRunStatus == "ok")
		}
	}

	// E56: a guest whose DHCP client sends a client id (systemd-networkd's default) has no
	// lease under its MAC. The lease that holds the address it reports is kept under that
	// id: the report teaches it, and the VM keeps it for discovery to match the lease on.
	@Test("E56: a report's address teaches the VM the client id of the lease that holds it")
	@MainActor func reportTeachesTheLeaseClientID() throws {
		let id = "ff,f1:f5:dd:7f:0:2:0:0:ab:11:b5:33:c7:d7:f3:c8:58:7d"
		let leases = """
			{
				ip_address=192.168.64.17
				hw_address=\(id)
				identifier=\(id)
				lease=0x66aa0001
			}
			{
				ip_address=192.168.64.30
				hw_address=1,3a:1:2:3:4:5
				identifier=1,3a:1:2:3:4:5
				lease=0x66aa5555
			}
			"""
		let dir = TestEnvironment.scratchURL
			.appendingPathComponent("machman-report-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		func polled(_ text: String) throws -> GuestReport {
			let path = dir.appendingPathComponent("report.env").path
			try text.write(toFile: path, atomically: true, encoding: .utf8)
			return try #require(GuestReport.poll(atPath: path, since: nil) { leases }?.report)
		}
		let report = try polled("USER=admin\nIP=192.168.64.17\n")
		#expect(report.leaseClientID == id)
		// A lease kept under a MAC teaches none; neither does a report without an address.
		#expect(try polled("USER=admin\nIP=192.168.64.30\n").leaseClientID == nil)
		#expect(try polled("USER=admin\n").leaseClientID == nil)
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "client-id")
			let vm = try VMConfig(name: "client-id", memorySize: 1 << 30, cpuCount: 2)
			#expect(try report.apply(to: vm, stampedAt: Date()).ssh)
			let saved = try VMConfig.load(name: "client-id").ssh
			#expect(saved?.dhcpClientID == id)
			#expect(saved?.lastAddress == "192.168.64.17")
		}
	}

	@Test func oversizedValuesAndFilesAreRefused() {
		let huge = String(repeating: "x", count: GuestReport.maxValueLength + 1)
		#expect(GuestReport.parse("USER=\(huge)").values["USER"] == nil)
		let dir = TestEnvironment.scratchURL
			.appendingPathComponent("machman-report-\(UUID().uuidString)")
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let big = dir.appendingPathComponent("report.env")
		try? Data(repeating: 0x41, count: GuestReport.maxBytes + 1).write(to: big)
		#expect(GuestReport.read(atPath: big.path) == nil)
	}

	// MARK: - The drop-box read (S40)

	private static func dropBox() throws -> URL {
		let dir = TestEnvironment.scratchURL
			.appendingPathComponent("machman-report-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	// S40: the guest owns the drop-box, so a link planted as report.env — to a report, to
	// a big host file, to /dev/zero — is never followed.
	@Test func linksInTheDropBoxAreNeverFollowed() throws {
		let dir = try Self.dropBox()
		defer { try? FileManager.default.removeItem(at: dir) }
		let real = dir.appendingPathComponent("real.env")
		try "USER=admin\n".write(to: real, atomically: true, encoding: .utf8)
		#expect(GuestReport.read(atPath: real.path)?.values["USER"] == "admin")
		let link = dir.appendingPathComponent("report.env")
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
		#expect(GuestReport.read(atPath: link.path) == nil)
		try FileManager.default.removeItem(at: link)
		try FileManager.default.createSymbolicLink(
			atPath: link.path, withDestinationPath: "/dev/zero")
		#expect(GuestReport.read(atPath: link.path) == nil)
	}

	// A FIFO with no writer would block an open or read forever; a directory, an empty file
	// and a huge sparse one are refused before a byte is read.
	@Test func onlyRegularFilesWithinTheCapAreRead() throws {
		let dir = try Self.dropBox()
		defer { try? FileManager.default.removeItem(at: dir) }
		let fifo = dir.appendingPathComponent("fifo.env")
		#expect(mkfifo(fifo.path, 0o600) == 0)
		#expect(GuestReport.read(atPath: fifo.path) == nil)
		#expect(GuestReport.read(atPath: dir.path) == nil)
		let empty = dir.appendingPathComponent("empty.env")
		#expect(FileManager.default.createFile(atPath: empty.path, contents: nil))
		#expect(GuestReport.read(atPath: empty.path) == nil)
		let sparse = dir.appendingPathComponent("sparse.env")
		#expect(FileManager.default.createFile(atPath: sparse.path, contents: nil))
		let handle = try FileHandle(forWritingTo: sparse)
		try handle.truncate(atOffset: 8 << 30)
		try handle.close()
		#expect(GuestReport.read(atPath: sparse.path) == nil)
		let exact = dir.appendingPathComponent("exact.env")
		var text = "USER=admin\n"
		text += String(repeating: "#", count: GuestReport.maxBytes - text.utf8.count - 1) + "\n"
		try text.write(to: exact, atomically: true, encoding: .utf8)
		#expect(GuestReport.read(atPath: exact.path)?.values["USER"] == "admin")
	}

	// The poll reads a file once per mtime: unchanged means nothing, a refused file still
	// moves the mark (so it is not retried every tick), a missing one is nothing at all.
	@Test func pollReadsEachVersionOnce() throws {
		let dir = try Self.dropBox()
		defer { try? FileManager.default.removeItem(at: dir) }
		let path = dir.appendingPathComponent("report.env").path
		#expect(GuestReport.poll(atPath: path, since: nil) == nil)
		try "USER=admin\n".write(toFile: path, atomically: true, encoding: .utf8)
		let first = try #require(GuestReport.poll(atPath: path, since: nil))
		#expect(first.report?.values["USER"] == "admin")
		#expect(GuestReport.poll(atPath: path, since: first.mtime) == nil)
		try FileManager.default.removeItem(atPath: path)
		try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/dev/zero")
		let link = try #require(GuestReport.poll(atPath: path, since: first.mtime))
		#expect(link.report == nil)
		#expect(GuestReport.poll(atPath: path, since: link.mtime) == nil)
	}

	// S22: the drop-box is guest-writable, and USER and the address end up in ~/.ssh —
	// "USER=a b" stopped every ssh on the Mac. A value without the shape it claims is
	// ignored and the stored one stays.
	@Test @MainActor func applyIgnoresUnsafeUsersAddressesAndKeys() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "hostile")
			let vm = try VMConfig(name: "hostile", memorySize: 1 << 30, cpuCount: 2)
			let stamp = Date(timeIntervalSince1970: 1_700_000_000)

			try GuestReport.parse("""
				USER=a b
				IP=10.0.0.1%en0
				HOST_KEY=@revoked x
				REVERSE_PUBKEY=command="x" ssh-ed25519 AAAA
				""").apply(to: vm, stampedAt: stamp)
			#expect(vm.ssh?.guestUser == nil)
			#expect(vm.ssh?.lastAddress == nil)
			#expect(vm.ssh?.guestHostKey == nil)
			#expect(vm.ssh?.reversePublicKey == nil)
			#expect(vm.ssh?.reverseStateValue != .pending)

			try GuestReport.parse("USER=admin\nIP=192.168.64.9")
				.apply(to: vm, stampedAt: stamp)
			#expect(vm.ssh?.guestUser == "admin")
			#expect(vm.ssh?.lastAddress == "192.168.64.9")

			try GuestReport.parse("USER=$(touch x)\nIP=evil.example")
				.apply(to: vm, stampedAt: stamp)
			#expect(vm.ssh?.guestUser == "admin")
			#expect(vm.ssh?.lastAddress == "192.168.64.9")
		}
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

	// S36: informational lines (a repair made, a boot refresh that will not run) arrive as
	// notes, not errors — a clean run lists none under Errors — and go with an uninstall.
	@Test @MainActor func notesAreNotErrors() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "notes")
			let vm = try VMConfig(name: "notes", memorySize: 1 << 30, cpuCount: 2)
			try GuestReport.parse("""
				SCRIPT_VERSION=4
				STATUS=ok
				NOTE_1=report-refresh: /etc/rc.local was not executable — re-enabled
				NOTE_2=a line without a step
				""").apply(to: vm, stampedAt: Date())
			#expect(vm.setup?.lastRunStatus == "ok")
			#expect(vm.setup?.errors.isEmpty == true)
			#expect(vm.setup?.notes == [
				GuestSetupNote(
					step: "report-refresh",
					message: "/etc/rc.local was not executable — re-enabled"),
				GuestSetupNote(step: "", message: "a line without a step"),
			])
			// The exact key NOTE (the run's one-sentence summary) is not a note.
			#expect(vm.setup?.lastRunNote == nil)
			#expect(try GuestReport.parse("UNINSTALLED=1").apply(to: vm, stampedAt: Date()).setup)
			#expect(vm.setup?.notes.isEmpty == true)
		}
	}

	// S17: a mount name with a space arrives whole — its row is TAB-separated — while the
	// space-separated rows every script writes for space-free names parse as before.
	@Test @MainActor func spacedMountNamesArriveWhole() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "spaced")
			let vm = try VMConfig(name: "spaced", memorySize: 1 << 30, cpuCount: 2)
			try GuestReport.parse("""
				SCRIPT_VERSION=4
				AUTOMOUNT_1=sshfs\tmy docs\t/mnt/machman/mounts/my docs
				AUTOMOUNT_2=sshfs docs /mnt/machman/mounts/docs
				AUTOMOUNT_3=sshfs projects /mnt/my mounts/projects
				""").apply(to: vm, stampedAt: Date())
			#expect(vm.setup?.automounts == [
				GuestAutomountInfo(
					kind: "sshfs", target: "my docs", path: "/mnt/machman/mounts/my docs"),
				GuestAutomountInfo(
					kind: "sshfs", target: "docs", path: "/mnt/machman/mounts/docs"),
				GuestAutomountInfo(
					kind: "sshfs", target: "projects", path: "/mnt/my mounts/projects"),
			])
		}
	}

	// The reported host key is pinned where the in-app session tabs look for it — under
	// the VM's alias, so the app never has to touch the user's own known_hosts.
	// CONSOLE_N lines arrive in the guest's enabled-compacted order; the k-th reported
	// name becomes the k-th ENABLED port's guestName — the guest's own word replaces the
	// boot-mode guess (EFI + FreeBSD reported ttyV0.0 while the daemon said hvc0).
	@Test @MainActor func applyNamesThePortsTheGuestReported() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "portnames")
			let vm = try VMConfig(name: "portnames", memorySize: 1 << 30, cpuCount: 2)
			try vm.addConsolePort()
			try vm.addConsolePort()
			try vm.addConsolePort()
			vm.consolePorts[0].enabled = false   // disabled: invisible to the guest
			#expect(try GuestReport.parse("""
				SCRIPT_VERSION=3
				CONSOLE_1=ttyV0.0 active
				CONSOLE_2=ttyV1.0 none
				""").apply(to: vm, stampedAt: Date()).setup)
			#expect(vm.consolePorts[0].guestName == nil)
			#expect(vm.consolePorts[1].guestName == "ttyV0.0")
			#expect(vm.consolePorts[2].guestName == "ttyV1.0")

			// Same report again: nothing changes, nothing fires.
			#expect(!(try GuestReport.parse("""
				SCRIPT_VERSION=3
				CONSOLE_1=ttyV0.0 active
				CONSOLE_2=ttyV1.0 none
				""").apply(to: vm, stampedAt: Date()).any))

			// A shorter report never blanks a name — absence isn't denial.
			#expect(try GuestReport.parse("""
				SCRIPT_VERSION=3
				CONSOLE_1=ttyV0.0 configured
				""").apply(to: vm, stampedAt: Date()).setup)
			#expect(vm.consolePorts[2].guestName == "ttyV1.0")

			// The names persist with the config.
			let reloaded = try VMConfig.load(name: "portnames")
			#expect(reloaded.consolePorts[1].guestName == "ttyV0.0")

			// Uninstalled: the guest forgot Machman; its names go with it.
			#expect(try GuestReport.parse("UNINSTALLED=1")
				.apply(to: vm, stampedAt: Date()).setup)
			#expect(vm.consolePorts.allSatisfy { $0.guestName == nil })
		}
	}

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
