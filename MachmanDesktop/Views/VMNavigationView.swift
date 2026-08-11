//
//  VMNavigationView.swift
//  MachmanDesktop
//
//  Created by Gustaf Franzen on 2025-03-31.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct VMNavigationView: View {
	@StateObject var viewModel: VMListViewModel
	let profiles: TerminalProfileStore
	@State private var lastSelection: String?
	@State private var expandedVMs: Set<String> = []
	@Binding private var selection: String?

	init(
		viewModel: VMListViewModel, selection: Binding<String?>,
		profiles: TerminalProfileStore
	) {
		_viewModel = StateObject(wrappedValue: viewModel)
		self._selection = selection
		self.profiles = profiles
	}

	var body: some View {
		NavigationSplitView {
			List(selection: $selection) {
				// A flat list with manual expansion: only VM rows are selectable, and a VM's
				// chevron toggles its subtree. Serial ports hang directly under the VM as
				// non-selectable rows — clicking one opens (or focuses) its terminal tab.
				ForEach(viewModel.vms) { item in
					let ports = (item.consolePorts ?? []) + (item.uartPorts ?? [])
					vmRow(item, hasPorts: !ports.isEmpty).tag(item.name)
					if !ports.isEmpty && expandedVMs.contains(item.name) {
						ForEach(ports) { port in
							PortRowView(
								vm: item.name, port: port, sessions: viewModel.terminals,
								onOpen: { openPort(item.name, port) },
								onProperties: { openPort(item.name, port, revealInfo: true) })
						}
					}
				}
			}
			.onChange(of: selection) {
				if let sel = selection {
					lastSelection = sel
					viewModel.select(name: sel)
				} else if let last = lastSelection {
					// The sidebar List drops its selection on its own when focus moves to
					// another app (the daemon's VM window). Re-assert the last selection
					// instead of letting the detail pane reset.
					selection = last
				}
			}
			// Keep the sidebar in sync when the SELECTED VM changes elsewhere (rename, delete).
			.onChange(of: viewModel.selectedName) {
				guard let name = viewModel.selectedName else { return }
				if selection != name {
					selection = name
				}
			}
			// After a daemon reconnect the view model is fresh but the window kept its
			// selection — restore it.
			.onAppear {
				if let sel = selection, viewModel.selectedName == nil {
					viewModel.select(name: sel)
				}
			}
			Button(action: {
				Task {
					if let name = await viewModel.createVM() {
						selection = name
						viewModel.select(name: name)
					}
				}
			}) {
				HStack {
					Image(systemName: MachmanSymbols.add)
					Text("New VM")
				}
			}
			.buttonStyle(.borderless)
			.padding()
		} detail: {
			VMTabContainerView(
				viewModel: viewModel, sessions: viewModel.terminals, profiles: profiles)
		}
		.alert(
			viewModel.presentedError?.title ?? "Error",
			isPresented: $viewModel.isErrorPresented,
			presenting: viewModel.presentedError
		) { _ in
			// Empty: SwiftUI supplies the default OK button.
		} message: { error in
			Text(error.message)
		}
		.alert(
			"MAC address conflict",
			isPresented: $viewModel.isForceStartPresented,
			presenting: viewModel.pendingForceStart
		) { pending in
			Button("Start Anyway") {
				viewModel.startVM(
					pending.name, headless: pending.headless, force: true,
					safe: pending.safe)
			}
			Button("Cancel", role: .cancel) {}
		} message: { pending in
			Text(pending.message)
		}
		.sheet(item: $viewModel.copyRequest) { vm in
			CopyVMSheet(vm: vm, viewModel: viewModel)
		}
		.sheet(item: $viewModel.safeSaveRequest) { vm in
			SafeSaveSheet(vm: vm, viewModel: viewModel)
		}
		.sheet(isPresented: Binding(
			get: { !viewModel.transfers.isEmpty },
			set: { _ in }   // data-driven: bars complete or fail, the user never dismisses
		)) {
			TransferProgressView(viewModel: viewModel)
		}
	}

	// VM row: selectable; the chevron on the RIGHT toggles the subtree without selecting.
	@ViewBuilder
	private func vmRow(_ item: VMInfo, hasPorts: Bool) -> some View {
		HStack {
			StatusIcon(state: item.state, windowOpen: item.windowOpen)
			Text(item.name).font(.callout)
			Spacer()
			if item.safeRun == true {
				Image(systemName: MachmanSymbols.safe)
					.foregroundColor(.yellow)
					.help("Running in safe mode (changes are discarded on stop)")
			}
			if hasPorts {
				Button {
					if expandedVMs.contains(item.name) {
						expandedVMs.remove(item.name)
					} else {
						expandedVMs.insert(item.name)
					}
				} label: {
					Image(systemName: expandedVMs.contains(item.name)
						? MachmanSymbols.disclosureExpanded : MachmanSymbols.disclosureCollapsed)
						.font(.caption).foregroundColor(.secondary)
				}
				.buttonStyle(.plain)
				.help(expandedVMs.contains(item.name) ? "Collapse" : "Expand serial ports")
			}
		}
	}

	// Open (or focus) a serial port's terminal tab, selecting its VM first so the pane shows.
	private func openPort(_ vm: String, _ port: SerialPortInfo, revealInfo: Bool = false) {
		selection = vm
		viewModel.select(name: vm)
		let ref = SerialPortRef(port)
		viewModel.terminals.openTab(
			vm: vm, ref: ref, socketPath: port.socketPath,
			profile: profiles.profile(vm: vm, ref: ref))
		if revealInfo { viewModel.showInfoPanel = true }
	}
}

// A non-selectable serial-port row: click opens/focuses its tab; the context menu offers
// Open / Close / Properties. Observes the sessions store so the open indicator stays live.
private struct PortRowView: View {
	let vm: String
	let port: SerialPortInfo
	@ObservedObject var sessions: TerminalSessions
	let onOpen: () -> Void
	let onProperties: () -> Void

	var body: some View {
		let ref = SerialPortRef(port)
		let open = sessions.isOpen(vm: vm, ref: ref)
		HStack {
			Image(systemName: port.kind == .console
				? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
				.foregroundColor(.secondary).font(.caption)
			Text(port.guestDevice).font(.callout)
			Spacer()
			if open {
				Circle().fill(Color.accentColor).frame(width: 6, height: 6)
					.help("Open in a tab")
			}
		}
		.padding(.leading, 24)
		.contentShape(Rectangle())
		.onTapGesture { onOpen() }
		.contextMenu {
			Button("Open") { onOpen() }
			Button("Close") { sessions.closeTab(vm: vm, ref: ref) }
				.disabled(!open)
			Button("Properties") { onProperties() }
		}
	}
}

#Preview {
	//VMNavigationView()
}
