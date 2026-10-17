//
//  THBSDGuideTests.swift
//  MachmanLabTests
//
//  L3 — the Setup Guide's BSD tab on FreeBSD 15 (QEMU, beside its carrier VM), every line
//  built by the same DesktopCore calls the guide page makes and run as printed: step 4 loads
//  fuse, step 5 mounts the share over sshfs from "the Mac" (the lab sshd on the lab gateway),
//  step 6 runs the installer; with doas and as root, without doubled prefixes. Then the run
//  over sshfs, its persisted fuse and usermount, and the rename-stable share link mounted at
//  boot. The guide's unapproved mount asks for the Mac password, which the lab sshd never
//  takes: the guest's keys stand in (T28), dropped before anything checks a boot.
//

import Foundation
import MachmanAPI
import MachmanDesktopCore
import Testing

enum THBSDGuide {
	/// Steps 4–6 of the BSD tab with `escalation`, the share unapproved (by password).
	static func steps(_ g: THBSDGuest, _ escalation: GuestEscalation) async throws -> [String] {
		[
			escalation.apply(GuestSetupCommands.bsdFuseLoad),
			escalation.apply(GuestSetupCommands.bsdShareMount(
				approvedGuestUser: nil, hostUser: try await g.hostUser,
				hostAddress: QEMUGuest.gateway, sharePath: try await g.sharePath)),
			GuestSetupCommands.run(.bsd, shareMounted: true)
				.replacingOccurrences(of: "doas ", with: escalation.prefix),
		]
	}

	static var options: THGuestOptions {
		var options = THGuestOptions()
		options.mountShare = false
		return options
	}

	/// The share's mount (its source and type) or "" when not mounted.
	static func shareMount(_ g: any THGuest) async throws -> String {
		try await g.check("mount | grep ' on \(GuestPaths.share) ' || true")
	}
}

// L3 — the BSD tab's commands on FreeBSD 15 under QEMU, through a carrier VM's share.
@Suite("L3 Guest Setup — the BSD guide's steps", .serialized, .enabled(if: Lab.runs(.l3)))
struct THBSDGuideTests {
	@Test("S9: the BSD tab's steps 4 to 6 run as printed with doas and mount the share")
	func guideStepsWithDoas() async throws {
		try await TH.withGuest(.freebsd15, THBSDGuide.options) { guest in
			let g = try #require(guest as? THBSDGuest)
			try await g.check("kldunload fusefs 2>/dev/null; true")
			let steps = try await THBSDGuide.steps(g, .doas)
			// Step 6 is the inspector's BSD run line exactly (W4-5's L3 half).
			#expect(steps[2] == GuestSetupCommands.run(.bsd, shareMounted: true))
			#expect(steps[2] == GuestEscalation.doas.apply(GuestCommand(TH.installer)))
			for line in steps.prefix(2) {
				let result = try await g.sh(line, user: "lab")
				#expect(result.status == 0, "\(line):\n\(result.output)")
			}
			#expect(try await g.sh("kldstat -v | grep -q fusefs").status == 0)
			let mounted = try await THBSDGuide.shareMount(g)
			#expect(mounted.contains("fusefs.sshfs") || mounted.contains("fuse"), "\(mounted)")
			try await g.asUserShell("lab") {
				let s = g.session()
				try s.start(steps[2])
				let run = try await s.drive(proceed: "q")
				#expect(run.status == 3, "\(run.output)")
				#expect(run.kinds.contains(.proceed), "the installer asked: \(run.output)")
			}
		}
	}

	@Test("S10: the run over sshfs reports TRANSPORT=sshfs and persists fusefs and usermount")
	func runOverSshfs() async throws {
		try await TH.withGuest(.freebsd15, THBSDGuide.options) { guest in
			let g = try #require(guest as? THBSDGuest)
			for line in try await THBSDGuide.steps(g, .doas).prefix(2) {
				try await g.check(line, user: "lab")
			}
			let mark = try await g.reportMark()
			let run = try await g.install(
				"-y --two-way --sshfs --mount-setup", user: "lab", escalation: .doas)
			#expect(run.status == 0, "\(run.output)")
			let setup = try await g.waitForReport(newerThan: mark)
			#expect(setup.lastTransport == "sshfs", "\(setup)")
			#expect(try await g.check("sysrc -n kld_list").contains("fusefs"))
			#expect(try await g.sh("grep -q '^vfs.usermount=1' /etc/sysctl.conf").status == 0)
			g.dropBootstrapKeys()
			try await g.reboot(remount: false)
			#expect(try await g.sh("kldstat -v | grep -q fusefs").status == 0)
			#expect(try await g.check("sysctl -n vfs.usermount") == "1")
		}
	}

	@Test("W3-30: steps 4 to 6 run with doas and as root without doubled prefixes")
	func guideStepsByEscalation() async throws {
		try await TH.withGuest(.freebsd15, THBSDGuide.options) { guest in
			let g = try #require(guest as? THBSDGuest)
			let withDoas = try await THBSDGuide.steps(g, .doas)
			for line in withDoas {
				#expect(!line.contains("doas doas"), "\(line)")
			}
			for line in withDoas.prefix(2) {
				let result = try await g.sh(line, user: "lab")
				#expect(result.status == 0, "\(line):\n\(result.output)")
			}
			#expect(!(try await THBSDGuide.shareMount(g)).isEmpty)
			let help = try await g.sh(withDoas[2] + " --help", user: "lab")
			#expect(help.status == 0, "\(help.output)")
			try await g.check("umount \(GuestPaths.share) && kldunload fusefs")
			let asRoot = try await THBSDGuide.steps(g, .root)
			for line in asRoot {
				#expect(!line.contains("doas") && !line.contains("sudo"), "\(line)")
			}
			for line in asRoot.prefix(2) {
				let result = try await g.sh(line)
				#expect(result.status == 0, "\(line):\n\(result.output)")
			}
			#expect(try await g.sh("kldstat -v | grep -q fusefs").status == 0)
			#expect(!(try await THBSDGuide.shareMount(g)).isEmpty)
			#expect(try await g.sh(asRoot[2] + " --help").status == 0)
		}
	}

	@Test("R3W2-14: guide steps mount .machman-shares/<marker>/ and it automounts at boot")
	func shareLinkAutomounts() async throws {
		try await TH.withGuest(.freebsd15, THBSDGuide.options) { guest in
			let g = try #require(guest as? THBSDGuest)
			let path = try await g.sharePath
			let marker = try g.marker()
			#expect(path.hasSuffix("/.machman-shares/\(marker)"), "\(path)")
			for line in try await THBSDGuide.steps(g, .doas).prefix(2) {
				try await g.check(line, user: "lab")
			}
			let mounted = try await THBSDGuide.shareMount(g)
			#expect(mounted.contains(".machman-shares/\(marker)/"), "\(mounted)")
			#expect(try await g.sh("test -f \(TH.installerPath)").status == 0)
			let run = try await g.install(
				"-y --two-way --automount-sshfs", user: "lab", escalation: .doas)
			#expect(run.status == 0, "\(run.output)")
			try await g.approveReverse()
			g.dropBootstrapKeys()
			try await g.reboot(remount: false)
			let atBoot = try await THBSDGuide.shareMount(g)
			#expect(atBoot.contains(".machman-shares/\(marker)/"), "\(atBoot)")
		}
	}

	// S65 (K6): on a guest without virtiofs the share — this VM's copy of Guest Setup, which
	// root runs — rode the boot's sshfs mount with allow_other, so every guest account could
	// swap install.sh. The boot mount is root's alone now: root reads the copy, an
	// unprivileged account can't even reach it.
	@Test("S65: after the boot mount no unprivileged FreeBSD account reaches the share's installer")
	func theShareIsRootsAloneAfterBoot() async throws {
		try await TH.withGuest(.freebsd15, THBSDGuide.options) { guest in
			let g = try #require(guest as? THBSDGuest)
			for line in try await THBSDGuide.steps(g, .doas).prefix(2) {
				try await g.check(line, user: "lab")
			}
			let run = try await g.install(
				"-y --two-way --automount-sshfs", user: "lab", escalation: .doas)
			#expect(run.status == 0, "\(run.output)")
			try await g.approveReverse()
			g.dropBootstrapKeys()
			try await g.reboot(remount: false)
			#expect(!(try await THBSDGuide.shareMount(g)).isEmpty, "the share mounts at boot")
			#expect(try await g.sh("test -r \(TH.installerPath)").status == 0, "root reads it")
			let lab = try await g.sh(
				"test -w \(TH.installerPath) || test -r \(TH.installerPath)", user: "lab")
			#expect(lab.status != 0, "an unprivileged account reaches the copy: \(lab.output)")
		}
	}

	@Test("CX1: the BSD guide's approved share mount works for a root guest user")
	func approvedMountForRoot() async throws {
		try await TH.withGuest(.freebsd15) { guest in
			let g = try #require(guest as? THBSDGuest)
			let run = try await g.install("-y --two-way --user root")
			#expect(run.status == 0, "\(run.output)")
			try await g.approveReverse()
			try await g.check("umount \(GuestPaths.share)")
			let mount = GuestEscalation.root.apply(GuestSetupCommands.bsdShareMount(
				approvedGuestUser: "root", hostUser: try await g.hostUser,
				hostAddress: QEMUGuest.gateway, sharePath: try await g.sharePath))
			let result = try await g.sh(mount)
			#expect(result.status == 0, "\(mount):\n\(result.output)")
		}
	}
}
