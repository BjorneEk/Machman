//
//  GuestSetupGuide.swift
//  MachmanDesktopCore
//
//  The Guest Setup guide's steps (Q21): the Linux, macOS and BSD tabs as lines, so a test
//  reads what a page says for a VM (the BSD step 5 asks for the Mac's password only until
//  the guest's key is approved) without hosting the sheet. GuestSetupGuidePage
//  (MachmanDesktopUI) draws them; its Info tab is prose and stays in the view. Steps skip
//  what the last setup run configured (the share automount, the guest → Mac key).
//

import Foundation
import MachmanAPI

public enum GuestSetupGuide {
	public enum Line: Equatable, Sendable {
		case step(Int, String)
		// A copyable command; `escalate` false for a line that already carries the page's
		// escalation.
		case command(GuestCommand, escalate: Bool)
		case note(String)
	}

	// The share mount the last setup run made, if any (either transport's share automount).
	static func shareAutomount(_ vm: VMInfo) -> GuestAutomountInfo? {
		(vm.setup?.automounts ?? []).first {
			$0.kind == MountKind.virtiofs
				|| ($0.kind == MountKind.sshfs && $0.target == "@share")
		}
	}

	public static func linux(_ vm: VMInfo) -> [Line] {
		var lines: [Line] = [.step(1, "Add (+) › Installers › Guest Setup, then boot the guest.")]
		if let auto = shareAutomount(vm) {
			lines += [
				.step(2, "The share automounts (\(auto.kind)) at \(auto.path) — run the script:"),
				.command(GuestCommand(GuestSetupInstallerInfo.runCommand()), escalate: true),
			]
		} else {
			lines += [
				.step(2, "Mount the share and run the script:"),
				.command(
					GuestSetupCommands.mountShareLine.and(GuestSetupInstallerInfo.runCommand()),
					escalate: true),
			]
		}
		return lines + [
			.note("It asks per feature — console logins, kernel boot output, SSH, boot "
				+ "automounts — and re-running it later reconfigures."),
			.step(3, "Undo it later:"),
			.command(
				GuestCommand(GuestSetupInstallerInfo.runCommand() + " --uninstall"),
				escalate: true),
		]
	}

	public static func macOS(_ vm: VMInfo, escalation: GuestEscalation) -> [Line] {
		[
			.step(1, "Add (+) › Installers › Guest Setup, then boot the guest — the share "
				+ "automounts (macOS 13+)."),
			.step(2, "In the guest’s Terminal, run the script:"),
			.command(GuestCommand(GuestSetupInstallerInfo.runFromAutomountCommand), escalate: true),
			.note("Volume missing (macOS 12)? Mount the share and run the script from there:"),
			.command(
				GuestCommand(GuestSetupCommands.macOS12MountShareAndRun(escalation)),
				escalate: false),
			.step(3, "Undo it later:"),
			.command(
				GuestCommand(GuestSetupInstallerInfo.runFromAutomountCommand + " --uninstall"),
				escalate: true),
		]
	}

	// No virtiofs driver in base, so the payload arrives over SSH unless the share already
	// automounts.
	public static func bsd(_ vm: VMInfo) -> [Line] {
		if let auto = shareAutomount(vm) {
			return [
				.step(1, "Start the VM — the share appears at \(auto.path)."),
				.step(2, "Run the installer:"),
				.command(GuestCommand(GuestSetupInstallerInfo.runCommand()), escalate: true),
				.step(3, "Undo it later:"),
				.command(
					GuestCommand(GuestSetupInstallerInfo.runCommand() + " --uninstall"),
					escalate: true),
			]
		}
		let approvedUser = vm.ssh?.reverseState == .approved ? vm.ssh?.guestUser : nil
		var lines: [Line] = [
			.step(1, "Start the VM."),
			.step(2, "Turn on Remote Login on this Mac (System Settings › General › Sharing)."),
			.step(3, "Install sshfs in the guest:"),
			.command(GuestCommand("pkg install fusefs-sshfs"), escalate: true),
			.note("On OpenBSD, run this instead and skip step 4:"),
			.command(GuestCommand("pkg_add sshfs-fuse"), escalate: true),
			.step(4, "FreeBSD only — load the fuse driver (skipped if it is already loaded):"),
			.command(GuestSetupCommands.bsdFuseLoad, escalate: true),
			approvedUser != nil
				? .step(5, "Mount Machman’s setup folder — the approved key needs no password:")
				: .step(5, "Mount Machman’s setup folder (it asks for your Mac password once):"),
			.command(
				GuestSetupCommands.bsdShareMount(
					approvedGuestUser: approvedUser, hostUser: vm.ssh?.hostUser ?? "<mac-user>",
					hostAddress: vm.ssh?.hostAddressForGuest ?? "<mac-address>",
					sharePath: vm.ssh?.setupSharePath ?? "<machman-share>"),
				escalate: true),
		]
		if vm.ssh?.setupSharePath == nil || vm.ssh?.hostAddressForGuest == nil {
			lines.append(.note("Boot the VM once so Machman can fill in this Mac’s address and "
				+ "the real path above."))
		}
		return lines + [
			.step(6, "Run the installer:"),
			.command(GuestCommand(GuestSetupInstallerInfo.runCommand()), escalate: true),
		]
	}
}
