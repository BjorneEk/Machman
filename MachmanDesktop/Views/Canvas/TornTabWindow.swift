//
//  TornTabWindow.swift
//  MachmanDesktop
//
//  A canvas tab torn off into its own window (1.0.4 UI). The payload is Codable, so torn
//  windows restore across app relaunches; the terminal reparents from the app-scoped
//  TerminalSessions (the source canvas tab closes on tear-off — one mount at a time).
//  Closing the window closes the tab: the controller is torn down with it.
//

import SwiftUI
import MachmanUI
import MachmanAPI

// What a torn-off window shows: one VM's config tab or one of its terminals.
struct TornTab: Codable, Hashable {
	var vm: String
	var tab: VMPaneTab
}

struct TornTabWindowView: View {
	@ObservedObject var connection: DaemonConnection
	@ObservedObject var profiles: TerminalProfileStore
	let payload: TornTab

	var body: some View {
		Group {
			if let viewModel = connection.viewModel,
				let vm = viewModel.vms.first(where: { $0.name == payload.vm }) {
				content(viewModel: viewModel, vm: vm)
			} else if connection.viewModel == nil {
				// Mid-reconnect: keep the window (and its controller) alive.
				ProgressView("Reconnecting…")
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				Text("\(payload.vm) is gone")
					.foregroundColor(.secondary)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.navigationTitle(title)
		// The OUTER view disappears only when the window closes (branch flips inside keep
		// it mounted) — closing the window closes the tab, tearing down its terminal.
		.onDisappear {
			if case .terminal(let ref) = payload.tab {
				connection.terminals.dropController(vm: payload.vm, ref: ref)
			}
		}
	}

	@ViewBuilder
	private func content(viewModel: VMListViewModel, vm: VMInfo) -> some View {
		switch payload.tab {
		case .config:
			VMConfigTabView(vm: vm, viewModel: viewModel)
		case .terminal(let ref):
			TerminalTabContent(
				sessions: connection.terminals, profiles: profiles, vm: vm, ref: ref,
				stillWanted: { true })
		}
	}

	private var title: String {
		switch payload.tab {
		case .config:
			return "\(payload.vm) — Configuration"
		case .terminal(let ref):
			return "\(payload.vm) — \(ref.guestDevice(macGuest: false))"
		}
	}
}
