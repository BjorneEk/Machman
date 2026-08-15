//
//  SSHHelpSheet.swift
//  MachmanDesktop
//
//  The SSH Setup guide: one script run inside the guest enables sshd and exchanges keys.
//  EFI/kernel VMs get Linux + FreeBSD tabs, macOS VMs a single page (ConsoleHelpSheet's
//  structure: fixed frame — sheets must not renegotiate layout — and the +20% type
//  scale). Content sources: the ssh-autoconfig research (launchctl-not-systemsetup,
//  per-distro service names, NixOS declarative stance).
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct SSHHelpSheet: View {
	let mode: BootInfo.Mode
	@Environment(\.dismiss) private var dismiss
	@State private var tab: GuestTab = .linux

	private enum GuestTab: String, CaseIterable {
		case linux = "Linux"
		case freebsd = "FreeBSD"
	}

	private static let titleSize: CGFloat = 19
	private static let textSize: CGFloat = 15.5
	private static let smallSize: CGFloat = 13

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
			if mode != .macOS {
				Picker("Guest OS", selection: $tab) {
					ForEach(GuestTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
				}
				.pickerStyle(.segmented)
				.labelsHidden()
			}
			ScrollView {
				VStack(alignment: .leading, spacing: 12) {
					switch (mode, tab) {
					case (.macOS, _):
						macOSSteps
						sharedTail(from: 4)
					case (_, .linux):
						linuxSteps
						sharedTail(from: 5)
					case (_, .freebsd):
						freebsdSteps   // manual path — no script, no shared tail
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

	// MARK: - Linux

	@ViewBuilder
	private var linuxSteps: some View {
		step(1, "Add (+) → Installers → SSH Setup, then boot the guest.")
		step(2, "As root (or with sudo), mount the share and run the script:")
		command(SSHSetupInfo.mountAndRunCommand)
		note("Root console without sudo? Drop the sudos and add:  --user <your name>")
		step(3, "The script enables sshd and installs this Mac's key for your user.")
		note("No sshd installed? It prints the install command — or re-run with --install. "
			+ "NixOS: --install edits configuration.nix and rebuilds for you.")
		step(4, "The Network inspector shows the guest's address, the ssh command, and "
			+ "the “ssh <vm>.machman” alias toggle.")
	}

	// MARK: - FreeBSD (manual — FreeBSD cannot mount the share)

	@ViewBuilder
	private var freebsdSteps: some View {
		intro("FreeBSD has no virtiofs driver, so the script cannot reach the guest — "
			+ "set SSH up by hand from the console instead.")
		step(1, "Enable sshd (the installer usually already did):")
		command("sysrc sshd_enable=YES && service sshd start")
		step(2, "Copy this Mac's key (SSH Setup inspector → Public key), then as your "
			+ "user in the console:")
		command("mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys")
		note("Paste the key, press Return, then Ctrl-D. Use a regular user — FreeBSD "
			+ "refuses root logins by default.")
		step(3, "The Network inspector shows the address once sshd answers — connect "
			+ "with ssh <user>@<address>.")
		note("Without the script there is no guest report, so the alias and session "
			+ "tabs stay off — plain ssh works fine.")
	}

	// MARK: - macOS guest

	@ViewBuilder
	private var macOSSteps: some View {
		step(1, "Add (+) → Installers → SSH Setup, then boot the guest — the share "
			+ "automounts (macOS 13+).")
		step(2, "In the guest's Terminal, run the script:")
		command(SSHSetupInfo.runCommand)
		note("It uses launchctl — the System Settings toggle is Full-Disk-Access-gated "
			+ "in a fresh VM.")
		step(3, "The Network inspector shows the address, the ssh command, and the "
			+ "“ssh <vm>.machman” alias toggle.")
	}

	// MARK: - Shared tail

	@ViewBuilder
	private func sharedTail(from n: Int) -> some View {
		step(n, "Two-way (guest → Mac): choose it at the script's prompt, then approve "
			+ "the key in the Network inspector — Remote Login on this Mac stays yours "
			+ "to enable.")
		step(n + 1, "Undo: --uninstall in the guest removes what it installed; “Reset "
			+ "SSH State” in the inspector forgets the Mac side.")
	}

	private func intro(_ text: String) -> some View {
		Text(text)
			.font(.system(size: Self.textSize))
			.foregroundStyle(.secondary)
			.fixedSize(horizontal: false, vertical: true)
	}

	// MARK: - Building blocks (ConsoleHelpSheet vocabulary)

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

	private func command(_ cmd: String) -> some View {
		HStack {
			Text(cmd)
				.font(.system(size: Self.smallSize, design: .monospaced))
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
			Spacer(minLength: 6)
			CopyToClipboardButton(cmd, tooltip: "Copy")
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
