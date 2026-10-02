//
//  TerminalTabContent.swift
//  MachmanDesktopUI
//
//  One terminal tab's content, shared by the canvas panes and torn-off windows: the live
//  SwiftTerm view when the port has a socket (created lazily with a spinner over the gap),
//  otherwise one sentence saying why there is none (SerialTabState, T10). The controller
//  comes from the app-scoped TerminalSessions, so the same terminal reparents wherever the
//  tab lives.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct TerminalTabContent: View {
	@ObservedObject var sessions: TerminalSessions
	let profiles: TerminalProfileStore
	let vm: VMInfo
	let ref: SerialPortRef
	// Re-checked on the deferred creation turn — the tab may have closed meanwhile.
	let stillWanted: @MainActor () -> Bool

	var body: some View {
		switch SerialTabState(vm: vm, ref: ref) {
		case .live(let socket):
			live(socket: socket)
		case .waiting:
			VStack(spacing: 10) {
				ProgressView()
				Text("Waiting for \(guestName)…")
					.foregroundColor(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		case .startVM:
			placeholder("Start the VM to open \(guestName).")
		case .restartVM:
			placeholder("Restart the VM to open \(guestName).")
		case .disabled(let running):
			placeholder(running
				? "Enable \(guestName) and restart the VM to open it."
				: "Enable \(guestName) and start the VM to open it.")
		case .unavailable(let reason):
			placeholder("\(guestName) isn't available on this Mac.", warning: true)
				.help(reason)
		}
	}

	private func live(socket: String) -> some View {
		Group {
			if let controller = sessions.serialTerminal(vm: vm.name, ref: ref) {
				SerialTerminalHost(controller: controller)
					.id(ObjectIdentifier(controller))   // swap the view on reloadTab
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.padding(6)
			} else {
				VStack(spacing: 10) {
					ProgressView()
					Text("Connecting to \(guestName)…")
						.foregroundColor(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.onAppear {
			// Deferred: reconnecting an existing controller flips its @Published
			// `connected` — publishing mid-view-update warns.
			let vmName = vm.name
			let profile = profiles.profile(vm: vmName, ref: ref)
			DispatchQueue.main.async { [weak sessions] in
				sessions?.ensureController(
					vm: vmName, ref: ref, socketPath: socket,
					profile: profile, stillWanted: stillWanted)
			}
		}
	}

	// The port's symbol over one sentence; a host that can't attach the port gets the
	// warning triangle instead.
	private func placeholder(_ text: String, warning: Bool = false) -> some View {
		VStack(spacing: 8) {
			Image(systemName: warning ? MachmanSymbols.warning
				: ref.kind == .console ? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
				.font(.largeTitle)
				.foregroundColor(warning ? MachmanColors.warning : .secondary)
			Text(text)
				.foregroundColor(.secondary)
				.multilineTextAlignment(.center)
		}
		.padding(.horizontal, 16)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private var port: SerialPortInfo? {
		let ports = ref.kind == .console ? vm.consolePorts : vm.uartPorts
		return ports?.first(where: { $0.index == ref.index })
	}

	private var guestName: String {
		port?.displayName(mode: vm.boot.mode) ?? ref.displayName(mode: vm.boot.mode)
	}
}
