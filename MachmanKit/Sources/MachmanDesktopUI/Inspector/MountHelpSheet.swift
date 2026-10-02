//
//  MountHelpSheet.swift
//  MachmanDesktopUI
//
//  How to reach one host folder from the guest (X5): the per-OS steps that used to live in
//  the mount inspector, which keeps one sentence, the guest path and the button here.
//  Steps only, the guide's look (HelpSheet.swift).
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct MountHelpSheet: View {
	let vm: VMInfo
	let mount: MountInfo

	var body: some View {
		HelpSheetFrame(
			symbol: MachmanSymbols.mount, title: "Mounting “\(mount.tag)” in the Guest", height: 440
		) {
			EmptyView()
		} page: {
			MountGuidePage(vm: vm, mount: mount)
		}
	}
}

// The sheet's page, apart from it so a render can show it whole.
struct MountGuidePage: View {
	let vm: VMInfo
	let mount: MountInfo

	private var guestPath: String { GuestSetupCommands.guestPath(of: mount, on: vm) }

	var body: some View {
		if mount.effectiveKind == MountKind.sshfs {
			sshfsSteps
		} else if vm.boot.mode == .macOS {
			macOSSteps
		} else {
			linuxSteps
			// A kernel boot IS Linux; an EFI guest may be a BSD.
			if vm.boot.mode != .linuxKernel {
				bsdSteps
			}
		}
	}

	@ViewBuilder
	private var linuxSteps: some View {
		if vm.boot.mode != .linuxKernel {
			HelpSectionTitle("Linux")
		}
		if mount.automountedAt != nil {
			HelpStep(1, "Guest Setup mounts the share at boot, so the folder is at \(guestPath).")
		} else {
			HelpStep(1, "Mount the share:")
			HelpCommand(GuestSetupCommands.mountShare(.linux))
			HelpNote("Linux 5.4 and later have the virtiofs driver built in.")
			HelpStep(2, "Open the folder at \(guestPath).")
			HelpNote("Guest Setup can mount the share at every boot.")
		}
	}

	@ViewBuilder
	private var bsdSteps: some View {
		HelpSectionTitle("FreeBSD and OpenBSD")
		HelpStep(1, "Set this mount’s Kind to sshfs — they have no virtiofs driver.")
	}

	@ViewBuilder
	private var macOSSteps: some View {
		HelpStep(1, "Open the folder at \(guestPath).")
		HelpNote("macOS 13 and later mount the share on their own.")
		HelpNote("Volume missing (macOS 12)? Mount the share, then open "
			+ "\(ConsoleLoginInstallerInfo.fallbackMountPoint)/\(mount.tag):")
		HelpCommand(GuestSetupCommands.macOS12MountShare())
	}

	@ViewBuilder
	private var sshfsSteps: some View {
		HelpStep(1, "Run Guest Setup in the guest and let it mount sshfs folders at boot.")
		HelpStep(2, "Approve guest → Mac access in the SSH section.")
		HelpStep(3, "Open the folder at \(guestPath).")
		HelpNote("Run Guest Setup again after adding another sshfs folder.")
	}
}
