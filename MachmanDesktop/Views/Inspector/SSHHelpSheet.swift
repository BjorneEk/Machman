//
//  SSHHelpSheet.swift
//  MachmanDesktop
//
//  The SSH Setup guide: four tabs, and a hard split between them. Linux / macOS / BSD are
//  STEPS — do this, then this — and nothing else; everything explanatory lives in Info, so
//  a user following the guide is never reading past the next command. How commands get
//  root is one choice at the top of the page (sudo / doas / root) applied to every command
//  below it: FreeBSD base ships neither sudo nor doas, OpenBSD ships doas, most Linux ships
//  sudo, and a root console needs none — so the guide adapts instead of assuming.
//
//  ConsoleHelpSheet's structure otherwise: fixed frame (sheets must not renegotiate
//  layout) and the +20% type scale.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct SSHHelpSheet: View {
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

	// macOS guests never see the Linux/BSD paths, and vice versa.
	private var tabs: [GuestTab] {
		vm.boot.mode == .macOS ? [.macOS, .info] : [.linux, .bsd, .info]
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
				Image(systemName: MachmanSymbols.deviceSSHSetup)
					.font(.system(size: 24))
					.foregroundStyle(.secondary)
				Text("SSH Setup")
					.font(.system(size: Self.titleSize, weight: .semibold))
				Spacer()
			}
			Picker("Guest OS", selection: $tab) {
				ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			// One choice for the whole page, stated once at the top: every command below
			// follows it. Guests differ — FreeBSD base has neither sudo nor doas, OpenBSD
			// has doas, a root console needs nothing.
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
				Text("The script runs inside the virtual machine. On this Mac, Machman "
					+ "only touches ~/.ssh — and only with your confirmation.")
					.font(.system(size: Self.smallSize))
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				Spacer()
				Button("Done") { dismiss() }
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding(22)
		// FIXED size on purpose (ConsoleHelpSheet lesson): a flexible ScrollView inside a
		// sheet makes the AppKit hosting view renegotiate during layout.
		.frame(width: 560, height: 620)
	}

	// MARK: - Linux (steps only)

	@ViewBuilder
	private var linuxSteps: some View {
		step(1, "Add (+) → Installers → SSH Setup, then boot the guest.")
		step(2, "Mount the share and run the script:")
		command(
			SSHSetupInfo.mountShareCommand + " && "
				+ SSHSetupInfo.runCommand(inShareAt: SSHSetupInfo.linuxMountPoint))
		step(3, "Undo it later:")
		command(SSHSetupInfo.runCommand(inShareAt: SSHSetupInfo.linuxMountPoint)
			+ " --uninstall")
	}

	// MARK: - macOS guest (steps only)

	@ViewBuilder
	private var macOSSteps: some View {
		step(1, "Add (+) → Installers → SSH Setup, then boot the guest — the share "
			+ "automounts (macOS 13+).")
		step(2, "In the guest's Terminal, run the script:")
		command(SSHSetupInfo.runFromAutomountCommand)
		step(3, "Undo it later:")
		command(SSHSetupInfo.runFromAutomountCommand + " --uninstall")
	}

	// MARK: - BSD (steps only — no virtiofs driver, so the payload arrives over SSH)

	private var hostUser: String { vm.ssh?.hostUser ?? "<mac-user>" }
	private var hostAddress: String { vm.ssh?.hostAddressForGuest ?? "<mac-address>" }
	private var sharePath: String { vm.ssh?.setupSharePath ?? "<machman-share>" }
	private var mountPoint: String { SSHSetupInfo.bsdMountPoint }

	@ViewBuilder
	private var bsdSteps: some View {
		intro("FreeBSD and OpenBSD have no virtiofs driver, so the setup folder is mounted "
			+ "over SSH instead — then the same script runs.")
		step(1, "Turn on Remote Login on this Mac (System Settings → General → Sharing).")
		step(2, "Install sshfs in the guest:")
		command("pkg install fusefs-sshfs")
		note("OpenBSD: pkg_add sshfs-fuse — and skip step 3; fuse is already in its kernel.")
		step(3, "FreeBSD only — load the fuse driver (skipped if it is already loaded):")
		command("kldstat -q -m fusefs || kldload fusefs")
		step(4, "Mount Machman's setup folder. This asks for your Mac account password — "
			+ "once, because keys are what the script is about to set up:")
		command("mkdir -p \(mountPoint) && sshfs \(hostUser)@\(hostAddress):'\(sharePath)' "
			+ "\(mountPoint) -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3")
		if vm.ssh?.setupSharePath == nil || vm.ssh?.hostAddressForGuest == nil {
			note("Boot the VM once so Machman can fill in this Mac's address and the real "
				+ "path above.")
		}
		step(5, "Run the installer:")
		command(SSHSetupInfo.runCommand(inShareAt: mountPoint))
		note("Mounting as root needs no system changes. The script keeps the fuse driver "
			+ "across reboots by itself, and can allow user mounts later if you ask it to.")
	}

	// MARK: - Info (everything that is not a step)

	@ViewBuilder
	private var infoPage: some View {
		sectionTitle("Where the details live")
		intro("The Network device's inspector carries this guest's address, a ready-to-paste "
			+ "ssh command, and the ~/.ssh alias.")
		sectionTitle("What the script does")
		bullet("Enables the guest's SSH server and installs this Mac's key for one user.")
		bullet("Asks first, always: it prints the whole plan, then does it. Run it with -n "
			+ "to see that plan and change nothing.")
		bullet("Reports back what it managed — including what it could not do, which the "
			+ "SSH Setup inspector then shows.")
		sectionTitle("Options")
		optionRow("-n, --dry-run", "print the plan and exit")
		optionRow("-v, --verbose", "narrate every decision and command")
		optionRow("-y, --yes", "never ask; take the defaults")
		optionRow("--user <name>", "set SSH up for this user")
		optionRow("--two-way", "also configure guest → host SSH")
		optionRow("--sshfs", "install sshfs (implies --two-way)")
		optionRow("--install", "install missing packages")
		optionRow("--uninstall", "remove everything it installed")
		note("Every question the script can ask has a flag, so the same script runs "
			+ "unattended.")
		sectionTitle("Two-way and sshfs")
		intro("--two-way lets the guest ssh back to this Mac; approve the key in the "
			+ "Network inspector before it works. sshfs rides that link, so a guest can "
			+ "mount host folders without virtiofs.")
		sectionTitle("Undoing it")
		intro("--uninstall removes what the script installed in the guest; “Reset SSH "
			+ "State” in this inspector forgets the Mac side.")
	}

	// MARK: - Building blocks (ConsoleHelpSheet vocabulary)

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
				.frame(width: 130, alignment: .leading)
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
