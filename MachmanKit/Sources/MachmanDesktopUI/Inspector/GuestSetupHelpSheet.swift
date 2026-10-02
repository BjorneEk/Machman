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
			footer: "The script runs inside the virtual machine and asks before every "
				+ "change. On this Mac, Machman only touches ~/.ssh — and only with "
				+ "your confirmation."
		) {
			Picker("Guest OS", selection: $tab) {
				ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			// One choice for the whole page, stated once at the top: every command below
			// follows it.
			if tab != .info {
				HStack(spacing: 10) {
					Text("Run commands as")
						.font(.system(size: HelpSheetType.small))
						.foregroundStyle(.secondary)
					Picker("Run commands as", selection: Binding(
						get: { resolved }, set: { escalation = $0 })) {
						ForEach(escalations) { Text($0.label).tag($0) }
					}
					.pickerStyle(.segmented)
					.labelsHidden()
					.frame(width: 190)
					Spacer()
				}
				.padding(.top, 2)
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
		HelpStep(1, "Add (+) → Installers → Guest Setup, then boot the guest.")
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
		HelpStep(1, "Add (+) → Installers → Guest Setup, then boot the guest — the share "
			+ "automounts (macOS 13+).")
		HelpStep(2, "In the guest's Terminal, run the script:")
		command(GuestSetupInstallerInfo.runFromAutomountCommand)
		HelpNote("Volume missing (macOS 12 guests)? "
			+ ConsoleLoginInstallerInfo.fallbackMountCommand)
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
			HelpIntro("This guest automounts the share over \(auto.kind) at boot — no "
				+ "bootstrap needed while that holds.")
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
		HelpIntro("FreeBSD and OpenBSD have no virtiofs driver, so the setup folder is mounted "
			+ "over SSH instead — then the same script runs.")
		HelpStep(1, "Start the VM — the payload is generated fresh at boot and served only "
			+ "while it runs.")
		HelpStep(2, "Turn on Remote Login on this Mac (System Settings → General → Sharing).")
		HelpStep(3, "Install sshfs in the guest:")
		command("pkg install fusefs-sshfs")
		HelpNote("OpenBSD: pkg_add sshfs-fuse — and skip step 4; fuse is already in its kernel.")
		HelpStep(4, "FreeBSD only — load the fuse driver (skipped if it is already loaded):")
		command(GuestSetupCommands.bsdFuseLoad)
		let approvedUser = reverseApproved ? vm.ssh?.guestUser : nil
		if approvedUser != nil {
			HelpStep(5, "Mount Machman's setup folder — this guest's key is approved, so the "
				+ "'mac' alias works without a password:")
		} else {
			HelpStep(5, "Mount Machman's setup folder. This asks for your Mac account "
				+ "password — once, because keys are what the script is about to set up:")
		}
		command(GuestSetupCommands.bsdShareMount(
			approvedGuestUser: approvedUser, hostUser: hostUser, hostAddress: hostAddress,
			sharePath: sharePath))
		HelpNote("Same folder Linux mounts over virtiofs, same path — so step 6 is the same "
			+ "command on every guest.")
		if vm.ssh?.setupSharePath == nil || vm.ssh?.hostAddressForGuest == nil {
			HelpNote("Boot the VM once so Machman can fill in this Mac's address and the real "
				+ "path above.")
		}
		HelpStep(6, "Run the installer:")
		command(GuestSetupInstallerInfo.runCommand())
		HelpNote("Mounting as root needs no system changes. The script keeps the fuse driver "
			+ "across reboots by itself, and can allow user mounts later if you ask it to.")
	}

	// MARK: - Info (everything that is not a step)

	@ViewBuilder
	private var infoPage: some View {
		HelpSectionTitle("Where the details live")
		HelpIntro("The Guest Setup inspector shows the report: install status, per-feature "
			+ "state, and errors. SSH specifics (address, alias, guest → Mac approval) "
			+ "live in the SSH section.")
		HelpSectionTitle("What the script does")
		HelpBullet("One script for everything guest-side: console logins, kernel boot output, "
			+ "SSH, guest → host SSH, sshfs, and boot automounts.")
		HelpBullet("Probes before offering: a feature the guest cannot do is skipped with the "
			+ "reason, never a failure.")
		HelpBullet("Asks first, always: it prints the whole plan, then does it. Run it with -n "
			+ "to see that plan and change nothing.")
		HelpBullet("Remembers its choices in the guest, so re-running offers reconfiguration "
			+ "and repairs older versions.")
		HelpSectionTitle("Options")
		HelpOptionRow("-n, --dry-run", "print the plan and exit")
		HelpOptionRow("-y, --yes", "never ask; take the defaults")
		HelpOptionRow("--user <name>", "set SSH up for this user")
		HelpOptionRow("--consoles \"…\"", "logins on exactly these consoles")
		HelpOptionRow("--kernel-console", "send kernel boot messages to a console — EDITS THE "
			+ "BOOT LOADER, so it is flag-only, keeps the display on tty0, and backs up "
			+ "grub.cfg; test in a safe run first")
		HelpOptionRow("--two-way", "also configure guest → host SSH")
		HelpOptionRow("--sshfs", "install sshfs (implies --two-way)")
		HelpOptionRow("--automount-virtiofs", "mount the share at boot")
		HelpOptionRow("--automount-sshfs", "mount sshfs folders at boot")
		HelpOptionRow("--install", "install missing packages")
		HelpOptionRow("--report-only", "refresh Machman's report, change nothing — a boot hook "
			+ "runs this so \"next boot\" states flip after a reboot")
		HelpOptionRow("--uninstall", "remove everything it installed")
		HelpNote("Every question the script can ask has a flag, so the same script runs "
			+ "unattended.")
		HelpSectionTitle("Consoles")
		HelpIntro("Linux with systemd usually gives the first console a login on its own; the "
			+ "script verifies, covers the rest, and can put kernel boot messages on one. "
			+ "OpenBSD has no virtio-console driver — the script says so and moves on.")
		HelpSectionTitle("Automounts")
		HelpIntro("The share is one fstab line (every mount is a folder inside it); sshfs "
			+ "folders ride the guest → host link, so approve the key in the SSH section "
			+ "before they connect.")
		HelpSectionTitle("Undoing it")
		HelpIntro("--uninstall removes what the script installed in the guest; “Reset Setup "
			+ "State” in the inspector forgets the report on the Mac side.")
	}

	// A copyable command, carrying the page's escalation on every command in the line —
	// a chained "sudo a && b" would run b as the user. `raw` is never escalated itself.
	private func command(_ raw: String, escalate: Bool = true) -> some View {
		HelpCommand(escalate ? escalation.apply(raw) : raw)
	}
}
