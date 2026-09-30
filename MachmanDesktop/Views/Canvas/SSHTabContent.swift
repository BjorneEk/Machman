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
import MachmanDesktopCore

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
		// Strict checking only when there is a pin to check against: the daemon serves
		// knownHostsPath once the file actually exists, and a host key means we know who
		// should answer. Otherwise accept-new — better than a TOFU prompt in a terminal
		// the user did not ask to be prompted in, and it cannot lock them out.
		if let knownHosts = ssh.knownHostsPath, ssh.guestHostKey != nil {
			arguments += [
				"-o", quotedOption("UserKnownHostsFile", path: knownHosts),
				"-o", "HostKeyAlias=\(ssh.alias ?? vm.name)",
				"-o", "StrictHostKeyChecking=yes",
			]
		} else {
			arguments += ["-o", "StrictHostKeyChecking=accept-new"]
		}
		return arguments + ["\(user)@\(address)"]
	}

	// ssh parses -o values with its own config parser, and UserKnownHostsFile takes a
	// SPACE-SEPARATED LIST — so an unquoted path under "Application Support" becomes three
	// filenames that do not exist, and strict checking then fails with "no host key is
	// known" (measured). Quoting inside the value is what ssh_config expects.
	private static func quotedOption(_ key: String, path: String) -> String {
		"\(key)=\"\(path)\""
	}
}

struct SSHTabContent: View {
	@ObservedObject var sessions: TerminalSessions
	@ObservedObject var viewModel: VMListViewModel
	let profiles: TerminalProfileStore
	let vm: VMInfo
	let ref: SSHSessionRef
	// Re-checked on the deferred creation turn — the tab may have closed meanwhile.
	let stillWanted: @MainActor () -> Bool
	// Torn-off windows adopt a session that already exists; they never start one. Without
	// this a window restored by the system at launch would silently open a NEW ssh
	// process for a session that died when the app quit.
	var adoptOnly = false

	var body: some View {
		if let controller = sessions.sshTerminal(vm: vm.name, ref: ref) {
			SSHSessionSurface(
				controller: controller,
				guestIsReachable: vm.ssh?.reachability == .ready,
				reconnect: reconnect,
				checkConnection: { viewModel.refreshSSH(vm.name) })
		} else if adoptOnly {
			VStack(spacing: 8) {
				Image(systemName: MachmanSymbols.deviceSSHSetup)
					.font(.largeTitle).foregroundColor(.secondary)
				Text("This session ended — sessions do not survive quitting Machman.")
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
				Text("Open a new one from the SSH section in the sidebar.")
					.font(.caption)
					.foregroundColor(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
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

	// The session's own reconnect: same tab, same controller, so the scrollback of what
	// just happened is still there to read.
	private func reconnect() {
		guard let arguments = SSHCommand.arguments(for: vm) else { return }
		sessions.reconnectSSHSession(
			vm: vm.name, ref: ref, arguments: arguments,
			profile: sessions.sshSessionProfileID(vm: vm.name, ref: ref)
				.flatMap { profiles.profile(id: $0) } ?? profiles.defaultProfile)
	}
}

// Observes the controller so the ended-state banner appears when the process exits. The
// banner is where a dropped session gets reconnected — that is where the user is looking.
private struct SSHSessionSurface: View {
	@ObservedObject var controller: SerialTerminalController
	let guestIsReachable: Bool
	let reconnect: () -> Void
	let checkConnection: () -> Void

	var body: some View {
		SerialTerminalHost(controller: controller)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.padding(6)
			.overlay(alignment: .top) {
				if !controller.connected {
					HStack(spacing: 8) {
						Text("Session ended.")
							.font(.caption)
						if guestIsReachable {
							Button("Reconnect", action: reconnect)
								.controlSize(.small)
						} else {
							Button("Check Connection", action: checkConnection)
								.controlSize(.small)
								.help("The guest is not answering on port 22 — probe again")
						}
					}
					.padding(.horizontal, 10)
					.padding(.vertical, 5)
					.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
					.padding(.top, 10)
				}
			}
	}
}
