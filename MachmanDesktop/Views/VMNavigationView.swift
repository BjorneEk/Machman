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
	@Binding private var selection: SidebarSelection?

	init(viewModel: VMListViewModel, selection: Binding<SidebarSelection?>) {
		_viewModel = StateObject(wrappedValue: viewModel)
		self._selection = selection
	}

	var body: some View {
		NavigationSplitView {
			List(selection: $selection) {
				ForEach(viewModel.vms) { item in
					let consoles = item.consolePorts ?? []
					let uarts = item.uartPorts ?? []
					if consoles.isEmpty && uarts.isEmpty {
						vmLabel(item).tag(SidebarSelection.vm(item.name))
					} else {
						// A VM with serial ports becomes an Xcode-style disclosure tree; the
						// Console/UART category rows only expand, the device leaves navigate.
						DisclosureGroup {
							if !consoles.isEmpty {
								serialCategory(
									"Console", MachmanSymbols.serialConsole, consoles,
									item.name, .console)
							}
							if !uarts.isEmpty {
								serialCategory(
									"UART", MachmanSymbols.serialUart, uarts, item.name, .uart)
							}
						} label: {
							vmLabel(item).tag(SidebarSelection.vm(item.name))
						}
					}
				}
			}
			.onChange(of: selection) {
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

	@ViewBuilder
	private func vmLabel(_ item: VMInfo) -> some View {
		HStack {
			StatusIcon(state: item.state, windowOpen: item.windowOpen)
			Text(item.name).font(.callout)
			Spacer()
			// Right-aligned shield: this VM is running a discardable copy.
			if item.safeRun == true {
				Image(systemName: MachmanSymbols.safe)
					.foregroundColor(.yellow)
					.help("Running in safe mode (changes are discarded on stop)")
			}
		}
	}

	@ViewBuilder
	private func serialCategory(
		_ label: String, _ symbol: String, _ ports: [SerialPortInfo], _ vm: String,
		_ kind: SerialPortKind
	) -> some View {
		DisclosureGroup {
			ForEach(ports) { port in
				HStack {
					Image(systemName: symbol).foregroundColor(.secondary)
					Text(port.guestDevice).font(.callout)
				}
				.tag(SidebarSelection.serial(vm: vm, kind: kind, index: port.index))
			}
		} label: {
			HStack {
				Image(systemName: symbol).foregroundColor(.secondary)
				Text(label).font(.caption).foregroundColor(.secondary)
			}
		}
	}
}

#Preview {
	//VMNavigationView()
}
