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
	@State private var navigate = false
	@State private var lastSelection: SidebarSelection?
	@State private var expandedVMs: Set<String> = []
	@State private var expandedCategories: Set<String> = []   // "<vm>|console" / "<vm>|uart"
	@Binding private var selection: SidebarSelection?

	init(viewModel: VMListViewModel, selection: Binding<SidebarSelection?>) {
		_viewModel = StateObject(wrappedValue: viewModel)
		self._selection = selection
	}

	var body: some View {
		NavigationSplitView {
			List(selection: $selection) {
				// A flat list with manual expansion: a VM's chevron sits on the RIGHT and only
				// toggles its subtree (the row itself stays selectable); the Console/UART
				// category rows are wholly clickable to expand and are never selected; only the
				// device leaves navigate.
				ForEach(viewModel.vms) { item in
					let consoles = item.consolePorts ?? []
					let uarts = item.uartPorts ?? []
					let hasPorts = !consoles.isEmpty || !uarts.isEmpty
					vmRow(item, hasPorts: hasPorts).tag(SidebarSelection.vm(item.name))
					if hasPorts && expandedVMs.contains(item.name) {
						if !consoles.isEmpty {
							categoryRow(item.name, "Console", MachmanSymbols.serialConsole, .console)
							if expandedCategories.contains("\(item.name)|console") {
								ForEach(consoles) { deviceRow(item.name, .console, $0) }
							}
						}
						if !uarts.isEmpty {
							categoryRow(item.name, "UART", MachmanSymbols.serialUart, .uart)
							if expandedCategories.contains("\(item.name)|uart") {
								ForEach(uarts) { deviceRow(item.name, .uart, $0) }
							}
						}
					}
				}
			}
			.onChange(of: selection) {
				revealSelection()
				if let sel = selection {
					lastSelection = sel
					viewModel.select(name: sel.vmName)
					navigate = !navigate
				} else if let last = lastSelection {
					// The sidebar List drops its selection on its own when focus moves to
					// another app (the daemon's VM window). Re-assert the last selection
					// instead of letting the detail pane reset.
					selection = last
				}
			}
			// Keep the sidebar in sync when the SELECTED VM changes elsewhere (rename, delete);
			// leave an in-VM serial selection alone.
			.onChange(of: viewModel.selectedName) {
				guard let name = viewModel.selectedName else { return }
				if selection?.vmName != name {
					selection = .vm(name)
				}
			}
			// After a daemon reconnect the view model is fresh but the window kept its
			// selection — restore it.
			.onAppear {
				revealSelection()
				if let sel = selection, viewModel.selectedName == nil {
					viewModel.select(name: sel.vmName)
				}
			}
			Button(action: {
				Task {
					if let name = await viewModel.createVM() {
						selection = .vm(name)
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
			Group {
				switch selection {
				case .serial(let vm, let kind, let index):
					SerialPortDetailView(
						vmName: vm, kind: kind, index: index, viewModel: viewModel)
				default:
					MainVMView(viewModel: viewModel)
				}
			}
			.id(navigate)
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

	// Category row: whole row expands/collapses; never selected.
	@ViewBuilder
	private func categoryRow(
		_ vm: String, _ label: String, _ symbol: String, _ kind: SerialPortKind
	) -> some View {
		let key = "\(vm)|\(kind.rawValue)"
		HStack {
			Image(systemName: symbol).foregroundColor(.secondary)
			Text(label).font(.caption).foregroundColor(.secondary)
			Spacer()
			Image(systemName: expandedCategories.contains(key)
				? MachmanSymbols.disclosureExpanded : MachmanSymbols.disclosureCollapsed)
				.font(.caption2).foregroundColor(.secondary)
		}
		.padding(.leading, 14)
		.contentShape(Rectangle())
		.onTapGesture {
			if expandedCategories.contains(key) {
				expandedCategories.remove(key)
			} else {
				expandedCategories.insert(key)
			}
		}
	}

	@ViewBuilder
	private func deviceRow(
		_ vm: String, _ kind: SerialPortKind, _ port: SerialPortInfo
	) -> some View {
		HStack {
			Image(systemName: kind == .console
				? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
				.foregroundColor(.secondary).font(.caption)
			Text(port.guestDevice).font(.callout)
		}
		.padding(.leading, 30)
		.tag(SidebarSelection.serial(vm: vm, kind: kind, index: port.index))
	}

	// Expand the tree down to the current selection so a selected leaf stays visible.
	private func revealSelection() {
		if case let .serial(vm, kind, _) = selection {
			expandedVMs.insert(vm)
			expandedCategories.insert("\(vm)|\(kind.rawValue)")
		}
	}
}

#Preview {
	//VMNavigationView()
}
