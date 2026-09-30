//
//  TerminalTabContent.swift
//  MachmanDesktopUI
//
//  One terminal tab's content, shared by the canvas panes and torn-off windows: the live
//  SwiftTerm view when the port has a socket (created lazily with a spinner over the gap),
//  a start-the-VM placeholder otherwise. The controller comes from the app-scoped
//  TerminalSessions, so the same terminal reparents wherever the tab lives.
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
		if let socket = socketPath {
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
		} else {
			VStack(spacing: 8) {
				Image(systemName: ref.kind == .console
					? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
					.font(.largeTitle).foregroundColor(.secondary)
				Text("Start the VM to open \(guestName).")
					.foregroundColor(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
	}

	private var port: SerialPortInfo? {
		let ports = ref.kind == .console ? vm.consolePorts : vm.uartPorts
		return ports?.first(where: { $0.index == ref.index })
	}

	private var socketPath: String? { port?.socketPath }

	private var guestName: String {
		port?.displayName(mode: vm.boot.mode) ?? ref.displayName(mode: vm.boot.mode)
	}
}
