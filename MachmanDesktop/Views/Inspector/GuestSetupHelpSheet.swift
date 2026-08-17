//
//  GuestSetupHelpSheet.swift
//  MachmanDesktop
//
//  The Guest Setup guide (merges the old Console and SSH sheets): four tabs, and a hard
//  split between them. Linux / macOS / BSD are STEPS — do this, then this — and nothing
//  else; everything explanatory lives in Info, so a user following the guide is never
//  reading past the next command. How commands get root is one choice at the top of the
//  page (sudo / doas / root) applied to every command below it: FreeBSD base ships
//  neither sudo nor doas, OpenBSD ships doas, most Linux ships sudo, and a root console
//  needs none — so the guide adapts instead of assuming.
//
//  Fixed frame on purpose (sheets must not renegotiate layout) and the +20% type scale.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct GuestSetupHelpSheet: View {
	let vm: VMInfo
	@Environment(\.dismiss) private var dismiss
	@State private var tab: GuestTab
	@State private var escalation: Escalation = .sudo

	init(vm: VMInfo) {
		self.vm = vm
		_tab = State(initialValue: vm.boot.mode == .macOS ? .macOS : .linux)
	}

	private enum GuestTab: String, CaseIterable {
		case linux = "Linux"
		case macOS = "macOS"
		case bsd = "BSD"
		case info = "Info"
	}

	// How a command gets root in this guest.
	private enum Escalation: String, CaseIterable, Identifiable {
		case sudo, doas, root

		var id: String { rawValue }
		var label: String { self == .root ? "root" : rawValue }
		var prefix: String { self == .root ? "" : rawValue + " " }
	}

	private static let titleSize: CGFloat = 19
	private static let textSize: CGFloat = 15.5
	private static let smallSize: CGFloat = 13

	// macOS guests never see the Linux/BSD paths; a kernel boot IS Linux.
	private var tabs: [GuestTab] {
		switch vm.boot.mode {
		case .macOS: return [.macOS, .info]
		case .linuxKernel: return [.linux, .info]
		case .efi: return [.linux, .bsd, .info]
		}
	}

	// FreeBSD/OpenBSD lead with doas (neither ships sudo in base); macOS has no doas.
	private var escalations: [Escalation] {
		switch tab {
		case .macOS: return [.sudo, .root]
		case .bsd: return [.doas, .sudo, .root]
		default: return [.sudo, .doas, .root]
		}
	}

	private var resolved: Escalation {
		escalations.contains(escalation) ? escalation : (escalations.first ?? .sudo)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 8) {
				Image(systemName: MachmanSymbols.deviceGuestSetup)
					.font(.system(size: 24))
					.foregroundStyle(.secondary)
				Text("Guest Setup")
					.font(.system(size: Self.titleSize, weight: .semibold))
				Spacer()
			}
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
						.font(.system(size: Self.smallSize))
						.foregroundStyle(.secondary)
					Picker("Run commands as", selection: $escalation) {
						ForEach(escalations) { Text($0.label).tag($0) }
					}
					.pickerStyle(.segmented)
					.labelsHidden()
					.frame(width: 190)
					Spacer()
				}
				.padding(.top, 2)
			}
			ScrollView {
				VStack(alignment: .leading, spacing: 12) {
					switch tab {
					case .linux: linuxSteps
					case .macOS: macOSSteps
					case .bsd: bsdSteps
					case .info: infoPage
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.vertical, 2)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			Divider()
			HStack(alignment: .firstTextBaseline) {
				Text("The script runs inside the virtual machine and asks before every "
					+ "change. On this Mac, Machman only touches ~/.ssh — and only with "
					+ "your confirmation.")
					.font(.system(size: Self.smallSize))
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				Spacer()
				Button("Done") { dismiss() }
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding(22)
		// FIXED size on purpose: a flexible ScrollView inside a sheet makes the AppKit
		// hosting view renegotiate during layout.
		.frame(width: 560, height: 620)
	}

	// MARK: - Linux (steps only)

	@ViewBuilder
	private var linuxSteps: some View {
		step(1, "Add (+) → Installers → Guest Setup, then boot the guest.")
		step(2, "Mount the share and run the script:")
		command(GuestPaths.mountShareCommand + " && " + GuestSetupInstallerInfo.runCommand())
		note("It asks per feature — console logins, kernel boot output, SSH, boot "
			+ "automounts — and re-running it later reconfigures.")
		step(3, "Undo it later:")
		command(GuestSetupInstallerInfo.runCommand() + " --uninstall")
	}

	// MARK: - macOS guest (steps only)

	@ViewBuilder
	private var macOSSteps: some View {
		step(1, "Add (+) → Installers → Guest Setup, then boot the guest — the share "
			+ "automounts (macOS 13+).")
		step(2, "In the guest's Terminal, run the script:")
		command(GuestSetupInstallerInfo.runFromAutomountCommand)
		note("Volume missing (macOS 12 guests)? "
			+ ConsoleLoginInstallerInfo.fallbackMountCommand)
		step(3, "Undo it later:")
		command(GuestSetupInstallerInfo.runFromAutomountCommand + " --uninstall")
	}

	// MARK: - BSD (steps only — no virtiofs driver, so the payload arrives over SSH)

	private var hostUser: String { vm.ssh?.hostUser ?? "<mac-user>" }
	private var hostAddress: String { vm.ssh?.hostAddressForGuest ?? "<mac-address>" }
	private var sharePath: String { vm.ssh?.setupSharePath ?? "<machman-share>" }
	// The same guest path Linux mounts the share at — only the mount verb differs.
	private var mountPoint: String { GuestPaths.share }

	@ViewBuilder
	private var bsdSteps: some View {
		intro("FreeBSD and OpenBSD have no virtiofs driver, so the setup folder is mounted "
			+ "over SSH instead — then the same script runs.")
		step(1, "Start the VM — the payload is generated fresh at boot and served only "
			+ "while it runs.")
		step(2, "Turn on Remote Login on this Mac (System Settings → General → Sharing).")
		step(3, "Install sshfs in the guest:")
		command("pkg install fusefs-sshfs")
		note("OpenBSD: pkg_add sshfs-fuse — and skip step 4; fuse is already in its kernel.")
		step(4, "FreeBSD only — load the fuse driver (skipped if it is already loaded):")
		command("kldstat -q -m fusefs || kldload fusefs")
		step(5, "Mount Machman's setup folder. This asks for your Mac account password — "
			+ "once, because keys are what the script is about to set up:")
		command("mkdir -p \(mountPoint) && sshfs \(hostUser)@\(hostAddress):'\(sharePath)' "
			+ "\(mountPoint) -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3")
		note("Same folder Linux mounts over virtiofs, same path — so step 6 is the same "
			+ "command on every guest.")
		if vm.ssh?.setupSharePath == nil || vm.ssh?.hostAddressForGuest == nil {
			note("Boot the VM once so Machman can fill in this Mac's address and the real "
				+ "path above.")
		}
		step(6, "Run the installer:")
		command(GuestSetupInstallerInfo.runCommand())
		note("Mounting as root needs no system changes. The script keeps the fuse driver "
			+ "across reboots by itself, and can allow user mounts later if you ask it to.")
	}

	// MARK: - Info (everything that is not a step)

	@ViewBuilder
	private var infoPage: some View {
		sectionTitle("Where the details live")
		intro("The Guest Setup inspector shows the report: install status, per-feature "
			+ "state, and errors. SSH specifics (address, alias, guest → Mac approval) "
			+ "live in the SSH section.")
		sectionTitle("What the script does")
		bullet("One script for everything guest-side: console logins, kernel boot output, "
			+ "SSH, guest → host SSH, sshfs, and boot automounts.")
		bullet("Probes before offering: a feature the guest cannot do is skipped with the "
			+ "reason, never a failure.")
		bullet("Asks first, always: it prints the whole plan, then does it. Run it with -n "
			+ "to see that plan and change nothing.")
		bullet("Remembers its choices in the guest, so re-running offers reconfiguration "
			+ "and repairs older versions.")
		sectionTitle("Options")
		optionRow("-n, --dry-run", "print the plan and exit")
		optionRow("-y, --yes", "never ask; take the defaults")
		optionRow("--user <name>", "set SSH up for this user")
		optionRow("--consoles \"…\"", "logins on exactly these consoles")
		optionRow("--kernel-console", "send kernel boot messages to a console — EDITS THE "
			+ "BOOT LOADER, so it is flag-only, keeps the display on tty0, and backs up "
			+ "grub.cfg; test in a safe run first")
		optionRow("--two-way", "also configure guest → host SSH")
		optionRow("--sshfs", "install sshfs (implies --two-way)")
		optionRow("--automount-virtiofs", "mount the share at boot")
		optionRow("--automount-sshfs", "mount sshfs folders at boot")
		optionRow("--install", "install missing packages")
		optionRow("--uninstall", "remove everything it installed")
		note("Every question the script can ask has a flag, so the same script runs "
			+ "unattended.")
		sectionTitle("Consoles")
		intro("Linux with systemd usually gives the first console a login on its own; the "
			+ "script verifies, covers the rest, and can put kernel boot messages on one. "
			+ "OpenBSD has no virtio-console driver — the script says so and moves on.")
		sectionTitle("Automounts")
		intro("The share is one fstab line (every mount is a folder inside it); sshfs "
			+ "folders ride the guest → host link, so approve the key in the SSH section "
			+ "before they connect.")
		sectionTitle("Undoing it")
		intro("--uninstall removes what the script installed in the guest; “Reset Setup "
			+ "State” in the inspector forgets the report on the Mac side.")
	}

	// MARK: - Building blocks

	private func intro(_ text: String) -> some View {
		Text(text)
			.font(.system(size: Self.textSize))
			.foregroundStyle(.secondary)
			.fixedSize(horizontal: false, vertical: true)
	}

	private func sectionTitle(_ text: String) -> some View {
		Text(text)
			.font(.system(size: Self.textSize, weight: .semibold))
			.padding(.top, 2)
	}

	private func bullet(_ text: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text("•").font(.system(size: Self.textSize))
			Text(text)
				.font(.system(size: Self.textSize))
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private func optionRow(_ flag: String, _ meaning: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text(flag)
				.font(.system(size: Self.smallSize, design: .monospaced))
				.frame(width: 160, alignment: .leading)
			Text(meaning)
				.font(.system(size: Self.smallSize))
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private func step(_ number: Int, _ text: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text("\(number)")
				.font(.system(size: Self.smallSize, weight: .semibold))
				.monospacedDigit()
				.frame(width: 20, height: 20)
				.background(Circle().fill(Color.primary.opacity(0.08)))
			Text(text)
				.font(.system(size: Self.textSize))
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	// A copyable command, carrying the page's escalation on every command in the line —
	// a chained "sudo a && b" would run b as the user.
	private func command(_ raw: String, escalate: Bool = true) -> some View {
		let text = escalate
			? SSHSetupInfo.escalated(raw, with: resolved.prefix) : raw
		return HStack(alignment: .top) {
			Text(text)
				.font(.system(size: Self.smallSize, design: .monospaced))
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
			Spacer(minLength: 6)
			CopyToClipboardButton(text, tooltip: "Copy")
		}
		.padding(7)
		.background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
		.padding(.leading, 28)
	}

	private func note(_ text: String) -> some View {
		Text(text)
			.font(.system(size: Self.smallSize))
			.foregroundStyle(.secondary)
			.fixedSize(horizontal: false, vertical: true)
			.padding(.leading, 28)
	}
}
