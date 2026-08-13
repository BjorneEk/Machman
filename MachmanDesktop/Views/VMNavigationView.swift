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
			// The sidebar is the SELECTED VM's device tree (1.0.4 UI); switching VMs is the
			// toolbar picker's job. `selection` (app-scoped) only mirrors the view model so
			// it survives daemon reconnects.
			Group {
				if let vm = viewModel.selected {
					VMDeviceTreeView(
						viewModel: viewModel, sessions: viewModel.terminals, vm: vm)
				} else {
					VStack(spacing: 12) {
						Text(viewModel.vms.isEmpty ? "No VMs yet" : "No VM selected")
							.foregroundColor(.secondary)
						Button(action: {
							Task {
								if let name = await viewModel.createVM() {
									viewModel.select(name: name)
								}
							}
						}) {
							Label("New VM", systemImage: MachmanSymbols.add)
						}
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
			}
			// Mirror the view model's selection into the window-scoped binding (rename,
			// delete, picker) so a daemon reconnect can restore it.
			.onChange(of: viewModel.selectedName) {
				if selection != viewModel.selectedName {
					selection = viewModel.selectedName
				}
			}
			// After a daemon reconnect the view model is fresh but the window kept its
			// selection — restore it.
			.onAppear {
				if let sel = selection, viewModel.selectedName == nil {
					viewModel.select(name: sel)
				}
			}
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

}

#Preview {
	//VMNavigationView()
}
