//
//  GuestSetupHelpSheet.swift
//  MachmanDesktopUI
//
//  The Guest Setup guide (merges the old Console and SSH sheets): four tabs, and a hard
//  split between them. Linux / macOS / BSD are STEPS — do this, then this — and nothing
//  else; everything explanatory lives in Info, so a user following the guide is never
//  reading past the next command. How commands get root is one choice at the top of the
//  page (sudo / doas / root) applied to every command below it: FreeBSD base ships
//  neither sudo nor doas, OpenBSD ships doas, most Linux ships sudo, and a root console
//  needs none — so the guide adapts instead of assuming.
//
//  The frame, the +20% type scale and the building blocks are HelpSheet.swift's.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct GuestSetupHelpSheet: View {
	let vm: VMInfo
	@State private var tab: GuestTab
	// The page's pick; nil until the user picks, which means the tab's usual one.
	@State private var escalation: GuestEscalation?

	// `tab` and `escalation` open the sheet on that page and choice (render scenes).
	init(vm: VMInfo, tab: GuestTab? = nil, escalation: GuestEscalation? = nil) {
		self.vm = vm
		_tab = State(initialValue: tab ?? (vm.boot.mode == .macOS ? .macOS : .linux))
		_escalation = State(initialValue: escalation)
	}

	enum GuestTab: String, CaseIterable {
		case linux = "Linux"
		case macOS = "macOS"
		case bsd = "BSD"
		case info = "Info"
	}

	// macOS guests never see the Linux/BSD paths; a kernel boot IS Linux. An unknown mode
	// proves nothing, like EFI.
	private var tabs: [GuestTab] {
		switch vm.boot.mode {
		case .macOS: return [.macOS, .info]
		case .linuxKernel: return [.linux, .info]
		case .efi, .unknown: return [.linux, .bsd, .info]
		}
	}

	// The tab's choices, its usual one first (GuestSetupCommands: FreeBSD/OpenBSD lead with
	// doas, macOS has none) — the inspector's commands use that first one too.
	private var escalations: [GuestEscalation] {
		switch tab {
		case .macOS: return GuestSetupCommands.escalations(for: .macOS)
		case .bsd: return GuestSetupCommands.escalations(for: .bsd)
		case .linux, .info: return GuestSetupCommands.escalations(for: .linux)
		}
	}

	// The user's pick where this tab offers it, else the tab's usual one.
	private var resolved: GuestEscalation {
		escalation.flatMap { escalations.contains($0) ? $0 : nil } ?? escalations[0]
	}

	var body: some View {
		HelpSheetFrame(
			symbol: MachmanSymbols.deviceGuestSetup, title: "Guest Setup",
			footer: "Everything asks first: the script before each change in the guest, and "
				+ "Machman before touching ~/.ssh, the only thing it changes on this Mac."
		) {
			Picker("Guest OS", selection: $tab) {
				ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			// One choice for the whole page, stated once at the top: every command below
			// follows it.
			if tab != .info {
				HelpRunAsPicker(
					choices: escalations,
					selection: Binding(get: { resolved }, set: { escalation = $0 }))
			}
		} page: {
			GuestSetupGuidePage(vm: vm, tab: tab, escalation: resolved)
		}
	}
}

// One tab of the guide, apart from the sheet so a render can show a whole page.
struct GuestSetupGuidePage: View {
	let vm: VMInfo
	let tab: GuestSetupHelpSheet.GuestTab
	let escalation: GuestEscalation

	var body: some View {
		switch tab {
		case .linux: linuxSteps
		case .macOS: macOSSteps
		case .bsd: bsdSteps
		case .info: infoPage
		}
	}

	// MARK: - Linux (steps only)

	// What the guest already does on its own — steps skip what the last setup run
	// configured (the share automount, the guest → host key).
	private var shareAutomount: GuestAutomountInfo? {
		(vm.setup?.automounts ?? []).first {
			$0.kind == MountKind.virtiofs
				|| ($0.kind == MountKind.sshfs && $0.target == "@share")
		}
	}
	private var reverseApproved: Bool { vm.ssh?.reverseState == .approved }

	@ViewBuilder
	private var linuxSteps: some View {
		HelpStep(1, "Add (+) › Installers › Guest Setup, then boot the guest.")
		if let auto = shareAutomount {
			HelpStep(2, "The share automounts (\(auto.kind)) at \(auto.path) — run the script:")
			command(GuestSetupInstallerInfo.runCommand())
		} else {
			HelpStep(2, "Mount the share and run the script:")
			command(GuestPaths.mountShareCommand + " && "
				+ GuestSetupInstallerInfo.runCommand())
		}
		HelpNote("It asks per feature — console logins, kernel boot output, SSH, boot "
			+ "automounts — and re-running it later reconfigures.")
		HelpStep(3, "Undo it later:")
		command(GuestSetupInstallerInfo.runCommand() + " --uninstall")
	}

	// MARK: - macOS guest (steps only)

	@ViewBuilder
	private var macOSSteps: some View {
		HelpStep(1, "Add (+) › Installers › Guest Setup, then boot the guest — the share "
			+ "automounts (macOS 13+).")
		HelpStep(2, "In the guest’s Terminal, run the script:")
		command(GuestSetupInstallerInfo.runFromAutomountCommand)
		HelpNote("Volume missing (macOS 12)? Mount the share and run the script from there:")
		command(GuestSetupCommands.macOS12MountShareAndRun(escalation), escalate: false)
		HelpStep(3, "Undo it later:")
		command(GuestSetupInstallerInfo.runFromAutomountCommand + " --uninstall")
	}

	// MARK: - BSD (steps only — no virtiofs driver, so the payload arrives over SSH)

	private var hostUser: String { vm.ssh?.hostUser ?? "<mac-user>" }
	private var hostAddress: String { vm.ssh?.hostAddressForGuest ?? "<mac-address>" }
	private var sharePath: String { vm.ssh?.setupSharePath ?? "<machman-share>" }

	@ViewBuilder
	private var bsdSteps: some View {
		if let auto = shareAutomount {
			HelpStep(1, "Start the VM — the share appears at \(auto.path).")
			HelpStep(2, "Run the installer:")
			command(GuestSetupInstallerInfo.runCommand())
			HelpStep(3, "Undo it later:")
			command(GuestSetupInstallerInfo.runCommand() + " --uninstall")
		} else {
			bsdBootstrapSteps
		}
	}

	@ViewBuilder
	private var bsdBootstrapSteps: some View {
		HelpStep(1, "Start the VM.")
		HelpStep(2, "Turn on Remote Login on this Mac (System Settings › General › Sharing).")
		HelpStep(3, "Install sshfs in the guest:")
		command("pkg install fusefs-sshfs")
		HelpNote("On OpenBSD, run this instead and skip step 4:")
		command("pkg_add sshfs-fuse")
		HelpStep(4, "FreeBSD only — load the fuse driver (skipped if it is already loaded):")
		command(GuestSetupCommands.bsdFuseLoad)
		let approvedUser = reverseApproved ? vm.ssh?.guestUser : nil
		if approvedUser != nil {
			HelpStep(5, "Mount Machman’s setup folder — the approved key needs no password:")
		} else {
			HelpStep(5, "Mount Machman’s setup folder (it asks for your Mac password once):")
		}
		command(GuestSetupCommands.bsdShareMount(
			approvedGuestUser: approvedUser, hostUser: hostUser, hostAddress: hostAddress,
			sharePath: sharePath))
		if vm.ssh?.setupSharePath == nil || vm.ssh?.hostAddressForGuest == nil {
			HelpNote("Boot the VM once so Machman can fill in this Mac’s address and the real "
				+ "path above.")
		}
		HelpStep(6, "Run the installer:")
		command(GuestSetupInstallerInfo.runCommand())
	}

	// MARK: - Info (everything that is not a step)

	@ViewBuilder
	private var infoPage: some View {
		HelpSectionTitle("Where the details live")
		HelpIntro("The Guest Setup inspector shows the script’s report, and the SSH section "
			+ "holds everything SSH.")
		HelpSectionTitle("What the script does")
		HelpBullet("One script for everything guest-side: console logins, kernel boot output, "
			+ "SSH, guest → Mac SSH, sshfs, and boot automounts.")
		HelpBullet("Probes before offering: a feature the guest cannot do is skipped with the "
			+ "reason, never a failure.")
		HelpBullet("Asks first, always: it prints the whole plan, then does it.")
		HelpBullet("Remembers its choices in the guest, so re-running offers reconfiguration "
			+ "and repairs older versions.")
		HelpSectionTitle("Options")
		HelpOptionRow("-n, --dry-run", "print the plan and exit")
		HelpOptionRow("-y, --yes", "never ask, take the defaults")
		HelpOptionRow("--user <name>", "set SSH up for this user")
		HelpOptionRow("--consoles \"…\"", "logins on exactly these consoles")
		HelpOptionRow("--kernel-console", "send kernel boot messages to a console — edits the "
			+ "boot loader, so try it in a safe run first")
		HelpOptionRow("--two-way", "also configure guest → Mac SSH")
		HelpOptionRow("--sshfs", "install sshfs (implies --two-way)")
		HelpOptionRow("--automount-virtiofs", "mount the share at boot")
		HelpOptionRow("--automount-sshfs", "mount sshfs folders at boot")
		HelpOptionRow("--install", "install missing packages")
		HelpOptionRow("--report-only", "refresh Machman’s report and change nothing")
		HelpOptionRow("--uninstall", "remove everything it installed")
		HelpNote("Every question the script can ask has a flag, so the same script runs "
			+ "unattended.")
		HelpSectionTitle("Consoles")
		HelpIntro("The script adds logins on the consoles that lack one (systemd often covers "
			+ "the first) and skips OpenBSD, which has no virtio-console driver.")
		HelpSectionTitle("FreeBSD and OpenBSD")
		HelpIntro("They have no virtiofs driver, so the setup folder comes over sshfs and the "
			+ "same script runs from it.")
		HelpSectionTitle("Automounts")
		HelpIntro("The share is one fstab line holding every mount, and sshfs folders connect "
			+ "once you approve the guest’s key in the SSH section.")
		HelpSectionTitle("Undoing it")
		HelpIntro("--uninstall removes what the script installed, and Reset Setup State… in "
			+ "the inspector forgets its report.")
	}

	// A copyable command, carrying the page's escalation on every command in the line —
	// a chained "sudo a && b" would run b as the user. `raw` is never escalated itself.
	private func command(_ raw: String, escalate: Bool = true) -> some View {
		HelpCommand(escalate ? escalation.apply(raw) : raw)
	}
}
