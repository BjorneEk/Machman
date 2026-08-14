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

// Which torn tabs currently have a window — the double-mount guard: opening a torn tab
// from the tree/canvas FOCUSES its window (openWindow dedups by value) instead of
// mounting the same TerminalView a second time. Pure window bookkeeping, so a shared
// registry beats threading one more store through every init.
@MainActor
final class TornTabRegistry: ObservableObject {
	static let shared = TornTabRegistry()
	@Published var open: Set<TornTab> = []

	func isOpen(vm: String, tab: VMPaneTab) -> Bool {
		open.contains(TornTab(vm: vm, tab: tab))
	}
}

struct TornTabWindowView: View {
	@ObservedObject var connection: DaemonConnection
	@ObservedObject var profiles: TerminalProfileStore
	let payload: TornTab
	@State private var showInspector = false

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
		// The tab's own inspector rides along: the serial inspector for terminals, the VM
		// inspector for the config/preview tab.
		.inspector(isPresented: $showInspector) {
			inspector
				.inspectorColumnWidth(min: 250, ideal: 300, max: 380)
		}
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				Button {
					showInspector.toggle()
				} label: {
					Image(systemName: MachmanSymbols.inspectorToggle)
				}
				.help(showInspector ? "Hide Inspector" : "Show Inspector")
			}
		}
		.onAppear {
			// Deferred: the registry is @Published; inserting mid-view-update warns.
			DispatchQueue.main.async {
				TornTabRegistry.shared.open.insert(payload)
			}
		}
		// The OUTER view disappears only when the window closes (branch flips inside keep
		// it mounted) — closing the window closes the tab, tearing down its terminal.
		// Deferred like the insert: both stores are @Published, and onDisappear runs
		// mid-view-update.
		.onDisappear { [payload, terminals = connection.terminals] in
			DispatchQueue.main.async {
				TornTabRegistry.shared.open.remove(payload)
				if case .terminal(let ref) = payload.tab {
					terminals.dropController(vm: payload.vm, ref: ref)
				}
			}
		}
	}

	@ViewBuilder
	private var inspector: some View {
		if let viewModel = connection.viewModel,
			let vm = viewModel.vms.first(where: { $0.name == payload.vm }) {
			Group {
				switch payload.tab {
				case .config:
					VMInspector(viewModel: viewModel, profiles: profiles, vm: vm)
				case .terminal(let ref):
					SerialInspector(
						vm: vm, ref: ref, viewModel: viewModel,
						sessions: connection.terminals, profiles: profiles)
				}
			}
			.formStyle(.grouped)
		} else {
			NoSelectionInspector()
		}
	}

	@ViewBuilder
	private func content(viewModel: VMListViewModel, vm: VMInfo) -> some View {
		switch payload.tab {
		case .config:
			VMPreviewTabView(vm: vm, viewModel: viewModel)
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
			// Resolve the live VM for its boot mode (and compacted index); a gone VM gets
			// the neutral EFI naming.
			let vm = connection.viewModel?.vms.first(where: { $0.name == payload.vm })
			let mode = vm?.boot.mode ?? .efi
			let port = (ref.kind == .console ? vm?.consolePorts : vm?.uartPorts)?
				.first(where: { $0.index == ref.index })
			let name = port?.displayName(mode: mode) ?? ref.displayName(mode: mode)
			return "\(payload.vm) — \(name)"
		}
	}
}
