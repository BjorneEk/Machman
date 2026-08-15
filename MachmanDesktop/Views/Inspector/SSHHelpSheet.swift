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

	private static let titleSize: CGFloat = 18
	private static let textSize: CGFloat = 14.5
	private static let smallSize: CGFloat = 12

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
						sharedTail(from: 5)
					case (_, .linux):
						linuxSteps
						sharedTail(from: 6)
					case (_, .freebsd):
						freebsdSteps
						sharedTail(from: 5)
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
		step(1, "Add the installer: Add (+) → Installers → SSH Setup, then boot the guest.")
		step(2, "Mount the share once and run the script (it prompts for two-way SSH; "
			+ "pass --two-way or --one-way to skip the prompt):")
		command(SSHSetupInfo.mountAndRunCommand)
		step(3, "What it does: starts the SSH server (systemd unit ssh/sshd, OpenRC on "
			+ "Alpine, plus the firewall rule openSUSE needs), installs this Mac's key "
			+ "for your user, and reports the guest's address back to Machman.")
		step(4, "No SSH server installed (Arch, desktop images)? The script prints the "
			+ "exact install command and stops — run it with --install to let it "
			+ "install the package itself.")
		note("NixOS is declarative: the script prints the services.openssh.enable "
			+ "snippet for configuration.nix instead of enabling anything, and still "
			+ "installs the key (honored once sshd is enabled).")
		step(5, "Done — the Network device's inspector shows the guest's address and the "
			+ "ready-to-copy ssh command; the alias toggle there makes "
			+ "“ssh <vm>.machman” work from any terminal.")
	}

	// MARK: - FreeBSD

	@ViewBuilder
	private var freebsdSteps: some View {
		step(1, "Add the installer: Add (+) → Installers → SSH Setup, then boot the guest.")
		step(2, "Mount the share once and run the script:")
		command(SSHSetupInfo.mountAndRunCommand)
		step(3, "What it does: sysrc sshd_enable=YES + service sshd start (sshd ships in "
			+ "base and the installer usually enables it already), installs this Mac's "
			+ "key for your user, and reports the guest's address back to Machman.")
		note("FreeBSD refuses root logins over SSH by default — the key is installed "
			+ "for the user who ran sudo, not root.")
		step(4, "Done — the Network device's inspector shows the address, the ssh "
			+ "command, and the “ssh <vm>.machman” alias toggle.")
	}

	// MARK: - macOS guest

	@ViewBuilder
	private var macOSSteps: some View {
		step(1, "Add the installer: Add (+) → Installers → SSH Setup, then boot the "
			+ "guest — the “My Shared Files” volume appears on its own (macOS 13+).")
		step(2, "In the guest's Terminal, run the script and enter your password:")
		command(SSHSetupInfo.runCommand)
		step(3, "What it does: enables Remote Login via launchctl (the System Settings "
			+ "toggle needs Full Disk Access and fails in a fresh VM — launchd control "
			+ "doesn't), creates the guest's host keys, installs this Mac's key for "
			+ "your user, and reports the guest's address back to Machman.")
		step(4, "Done — the Network device's inspector shows the address, the ssh "
			+ "command, and the “ssh <vm>.machman” alias toggle.")
	}

	// MARK: - Shared tail

	@ViewBuilder
	private func sharedTail(from n: Int) -> some View {
		step(n, "Two-way (guest → Mac): choose it at the prompt or re-run with "
			+ "--two-way. The guest makes its own key and Machman asks you to approve "
			+ "it before anything can log in to this Mac; it also needs Remote Login "
			+ "enabled here (System Settings → General → Sharing) — Machman never "
			+ "flips that itself. Afterwards “ssh mac” works inside the guest.")
		step(n + 1, "Undo: --uninstall removes everything the script installed in the "
			+ "guest (the SSH server stays enabled); the installer device can be "
			+ "disabled or removed any time — SSH keeps working, Machman just stops "
			+ "regenerating the payload. “Reset SSH State” in the inspector forgets "
			+ "the Mac side.")
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
