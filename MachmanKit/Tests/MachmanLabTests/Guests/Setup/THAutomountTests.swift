//
//  THAutomountTests.swift
//  MachmanLabTests
//
//  L3 — boot automounts: the share over virtiofs (fstab) and an sshfs-kind host folder over
//  the guest→Mac link (systemd's automount on Debian, the OpenRC boot script on Alpine),
//  through the lab sshd behind the guest's redirect once Machman approved the guest's key.
//  Every guest→Mac connection shows in the lab sshd's log.
//

import Foundation
import MachmanAPI
import Testing

enum THAutomount {
	/// The sshfs-kind host folder these rows mount, and the file it holds.
	static let tag = "projects"
	static let probe = "th-marker"

	static var options: THGuestOptions {
		var options = THGuestOptions()
		options.mounts = [tag: MountKind.sshfs]
		return options
	}

	/// Puts the probe file into the host folder of `g`'s scope.
	static func seed(_ g: any THGuest) throws {
		let dir = try TH.hostDir(g.agent, tag)
		try "th\n".write(toFile: dir + "/" + probe, atomically: true, encoding: .utf8)
	}

	static var mountpoint: String { GuestPaths.sshfsMountPoint(name: tag) }

	/// The approval the inspector's button sends, once the report offered the key.
	static func approve(_ g: any THGuest) async throws { try await g.approveReverse() }

	/// `ls` of the sshfs mountpoint as lab (systemd mounts it at this first access).
	static func list(_ g: any THGuest) async throws -> (status: Int32, output: String) {
		try await g.sh("ls \(mountpoint)", user: "lab", timeout: .seconds(60))
	}

	/// Where the sshfs boot mounts live: fstab under systemd, the OpenRC boot script else.
	static func sshfsLines(_ g: any THGuest) async throws -> String {
		g.kind == .debian
			? try await g.check("grep fuse.sshfs /etc/fstab; true")
			: try await g.check("cat /etc/local.d/machman-sshfs.start 2>/dev/null; true")
	}
}

// L3 — automounts on Debian (systemd) and Alpine (OpenRC).
@Suite("L3 Guest Setup — automounts", .serialized, .enabled(if: Lab.runs(.l3)))
struct THAutomountTests {
	@Test(
		"G9: share and sshfs automounts mount now, at boot, and uninstall exactly",
		arguments: [THGuestKind.debian, .alpine])
	func automountsLifecycle(kind: THGuestKind) async throws {
		try await TH.withGuest(kind, THAutomount.options) { g in
			try THAutomount.seed(g)
			let mac = try #require(g.mac, "no lab sshd: the guest→Mac half needs one")
			let pristine = try await THGuestFiles.fingerprint(g, paths: ["/etc"])
			let run = try await g.install(
				"-y --two-way --automount-virtiofs --automount-sshfs", user: "lab",
				escalation: kind.escalation)
			#expect(run.status == 0, "\(run.output)")
			#expect(try await g.sh("mountpoint -q \(GuestPaths.share)").status == 0)
			let share = try await g.check("grep ' \(GuestPaths.share) ' /etc/fstab; true")
			#expect(share.contains("host-share \(GuestPaths.share) virtiofs"), "\(share)")
			let sshfs = try await THAutomount.sshfsLines(g)
			#expect(sshfs.contains(THAutomount.mountpoint), "\(sshfs)")
			try await THAutomount.approve(g)
			if kind == .debian {
				let logins = mac.acceptedLogins.count
				let now = try await THAutomount.list(g)
				#expect(now.output.contains(THAutomount.probe), "\(now.output)")
				#expect(await mac.waitForLogins(moreThan: logins))
			}
			// At boot: both come back with no command run.
			let logins = mac.acceptedLogins.count
			try await g.reboot(remount: false)
			#expect(try await g.sh("mountpoint -q \(GuestPaths.share)").status == 0,
				"the share mounted at boot")
			let atBoot = try await THAutomount.list(g)
			#expect(atBoot.output.contains(THAutomount.probe), "\(atBoot.output)")
			#expect(await mac.waitForLogins(moreThan: logins), "the boot mount reached the Mac")
			// --uninstall: the fstab block, the state and the boot pieces go; /etc is as it was.
			let uninstall = try await g.install(
				"--uninstall -y", user: "lab", escalation: kind.escalation)
			#expect(uninstall.status == 0, "\(uninstall.output)")
			#expect(try await g.sh("grep -q \(try g.marker()) /etc/fstab").status != 0)
			#expect(try await g.sh("test -e \(kind.stateFile)").status != 0)
			if kind == .alpine {
				#expect(try await g.sh("test -e /etc/local.d/machman-sshfs.start").status != 0)
			}
			let after = try await THGuestFiles.fingerprint(g, paths: ["/etc"])
			let changed = try await THGuestFiles.changes(
				g, from: pristine, to: after, ignoring: [])
			#expect(changed.isEmpty, "/etc changed:\n\(changed)\n\(uninstall.output)")
		}
	}

	@Test("W2-7: an approved sshfs host folder mounts without a reboot")
	func approvedFolderMountsNow() async throws {
		try await TH.withGuest(.debian, THAutomount.options) { g in
			try THAutomount.seed(g)
			let mac = try #require(g.mac, "no lab sshd: the guest→Mac half needs one")
			let run = try await g.install(
				"-y --two-way --automount-sshfs", user: "lab", escalation: .sudo)
			#expect(run.status == 0, "\(run.output)")
			try await THAutomount.approve(g)
			let logins = mac.acceptedLogins.count
			let listed = try await THAutomount.list(g)
			#expect(listed.output.contains(THAutomount.probe), "\(listed.output)")
			#expect(await mac.waitForLogins(moreThan: logins), "the mount reached the Mac")
		}
	}

	// S46: a host folder reached through a link mounted "Not a directory": sshfs checks its
	// root with an SFTP LSTAT, which the Mac's sftp-server answers for the link itself. The
	// mount's source ends in "/" now, as the share's does (S45).
	@Test("S46: an sshfs host folder reached through a symlink mounts")
	func symlinkedFolderMounts() async throws {
		try await TH.withGuest(.debian, THAutomount.options) { g in
			try THAutomount.seed(g)
			_ = try #require(g.mac, "no lab sshd: the guest→Mac half needs one")
			// The VM's folder becomes a link to where its files are.
			let dir = try TH.hostDir(g.agent, THAutomount.tag)
			try FileManager.default.moveItem(atPath: dir, toPath: dir + "-real")
			try FileManager.default.createSymbolicLink(
				atPath: dir, withDestinationPath: dir + "-real")
			let run = try await g.install(
				"-y --two-way --automount-sshfs", user: "lab", escalation: .sudo)
			#expect(run.status == 0, "\(run.output)")
			try await THAutomount.approve(g)
			let listed = try await THAutomount.list(g)
			#expect(listed.output.contains(THAutomount.probe), "\(listed.output)")
		}
	}

	@Test(
		"W2-9: after a DHCP reboot the sshfs automount feature reads configured",
		arguments: [THGuestKind.debian, .alpine])
	func automountReadsConfiguredAfterReboot(kind: THGuestKind) async throws {
		try await TH.withGuest(kind, THAutomount.options) { g in
			try THAutomount.seed(g)
			let run = try await g.install(
				"-y --two-way --automount-virtiofs --automount-sshfs", user: "lab",
				escalation: kind.escalation)
			#expect(run.status == 0, "\(run.output)")
			try await THAutomount.approve(g)
			let written = g.reportFileDate()
			try await g.reboot(remount: false)
			// The boot copy's report, read where it landed (the host restamps a report only
			// when it says something new).
			try await g.waitForReportFile(newerThan: written)
			let report = try THGuestFiles.reportEnv(g.vm)
			let line = report["FEATURE_\(GuestFeature.sshfsAutomount)"] ?? ""
			#expect(line.hasPrefix("configured"), "the boot report: \(line)")
			#expect(!line.contains("no route to the Mac"), "\(line)")
			let setup = try #require(try await g.vm.info().setup)
			let feature = setup.features?.first { $0.id == GuestFeature.sshfsAutomount }
			#expect(feature?.configured == true, "\(setup.features ?? [])")
			for text in [feature?.reason, feature?.detail].compactMap({ $0 }) {
				#expect(!text.contains("no route to the Mac"), "\(text)")
			}
			let listed = try await THAutomount.list(g)
			#expect(listed.output.contains(THAutomount.probe), "\(listed.output)")
		}
	}
}
