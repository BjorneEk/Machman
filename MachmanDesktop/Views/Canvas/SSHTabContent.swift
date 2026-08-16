//
//  SSHTabContent.swift
//  MachmanDesktop
//
//  One ephemeral SSH tab's content: the shared SwiftTerm surface driven by a PTY-spawned
//  ssh (TerminalTabContent's lazy-creation shape). The session is one-shot — when the
//  process ends the terminal stays readable under a "session ended" banner; a new session
//  is a new tab.
//

import SwiftUI
import MachmanUI
import MachmanAPI

// argv for /usr/bin/ssh from daemon-served state — self-contained (-i + IdentitiesOnly),
// deliberately independent of the ~/.ssh integration so tabs work without consent.
//
// Host verification uses the VM's OWN known-hosts file, keyed by its alias: the app never
// writes the user's ~/.ssh (which is the promise the setup guide makes), the pin follows
// the guest rather than its address, and a guest whose key we already know is verified
// strictly. Keepalives matter because a guest that dies mid-session otherwise leaves the
// tab hanging with no output and no exit.
enum SSHCommand {
	static func arguments(for vm: VMInfo) -> [String]? {
		guard let ssh = vm.ssh, let user = ssh.guestUser, let address = ssh.address,
			let identity = ssh.identityFilePath else { return nil }
		var arguments = [
			"-i", identity,
			"-o", "IdentitiesOnly=yes",
			"-o", "ConnectTimeout=10",
			"-o", "ServerAliveInterval=15",
			"-o", "ServerAliveCountMax=3",
		]
		if let knownHosts = ssh.knownHostsPath {
			arguments += ["-o", "UserKnownHostsFile=\(knownHosts)"]
			arguments += ["-o", "HostKeyAlias=\(ssh.alias ?? vm.name)"]
			// A reported host key means we know exactly who should answer; without one
			// (a partial run, an older daemon) accept-new still beats a TOFU prompt in a
			// terminal the user did not ask to be prompted in.
			arguments += [
				"-o",
				ssh.guestHostKey == nil
					? "StrictHostKeyChecking=accept-new" : "StrictHostKeyChecking=yes",
			]
		} else {
			arguments += ["-o", "StrictHostKeyChecking=accept-new"]
		}
		return arguments + ["\(user)@\(address)"]
	}
}

struct SSHTabContent: View {
	@ObservedObject var sessions: TerminalSessions
	let profiles: TerminalProfileStore
	let vm: VMInfo
	let ref: SSHSessionRef
	// Re-checked on the deferred creation turn — the tab may have closed meanwhile.
	let stillWanted: @MainActor () -> Bool

	var body: some View {
		if let controller = sessions.sshController(vm: vm.name, ref: ref) {
			SSHSessionSurface(controller: controller)
		} else if let arguments = SSHCommand.arguments(for: vm) {
			VStack(spacing: 10) {
				ProgressView()
				Text("Connecting to \(ref.title)…")
					.foregroundColor(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.onAppear {
				// Deferred like the serial tabs: controller creation flips @Published
				// state, and onAppear runs mid-view-update.
				let vmName = vm.name
				let profile = profiles.defaultProfile
				DispatchQueue.main.async { [weak sessions] in
					sessions?.ensureSSHController(
						vm: vmName, ref: ref, arguments: arguments,
						profile: profile, stillWanted: stillWanted)
				}
			}
		} else {
			VStack(spacing: 8) {
				Image(systemName: MachmanSymbols.deviceSSHSetup)
					.font(.largeTitle).foregroundColor(.secondary)
				Text("This session cannot start — the VM needs to be running with a "
					+ "discovered SSH address.")
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
	}
}

// Observes the controller so the ended-state banner appears when the process exits.
private struct SSHSessionSurface: View {
	@ObservedObject var controller: SerialTerminalController

	var body: some View {
		SerialTerminalHost(controller: controller)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.padding(6)
			.overlay(alignment: .top) {
				if !controller.connected {
					Text("Session ended — close this tab; a new session is a new tab.")
						.font(.caption)
						.padding(.horizontal, 10)
						.padding(.vertical, 5)
						.background(.ultraThinMaterial,
							in: RoundedRectangle(cornerRadius: 6))
						.padding(.top, 10)
				}
			}
	}
}
