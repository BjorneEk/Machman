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
	@Binding private var selection: String?

	init(viewModel: VMListViewModel, selection: Binding<String?>) {
		_viewModel = StateObject(wrappedValue: viewModel)
		self._selection = selection
	}

	var body: some View {
		NavigationSplitView {
			List(selection: $selection) {
				ForEach(viewModel.vms) { item in
					HStack {
						StatusIcon(state: item.state, consoleOpen: item.consoleOpen)
						Text(item.name)
							.font(.callout)
						Spacer()
						// Right-aligned shield: this VM is running a discardable copy.
						if item.safeRun == true {
							Image(systemName: MachmanSymbols.safe)
								.foregroundColor(.yellow)
								.help("Running in safe mode (changes are discarded on stop)")
						}
					}
					.tag(item.name)
				}
			}
			.onChange(of: selection) {
				if let name = selection {
					viewModel.select(name: name)
					navigate = !navigate
				} else if viewModel.selectedName != nil {
					// The sidebar List drops its selection on its own when focus moves to
					// another app (the daemon's console window, on VM start). The view model
					// owns selection — re-assert it instead of letting the detail pane reset.
					selection = viewModel.selectedName
				}
			}
			// Keep the sidebar highlight in sync when the selection changes elsewhere
			// (rename, delete).
			.onChange(of: viewModel.selectedName) {
				if selection != viewModel.selectedName {
					selection = viewModel.selectedName
				}
			}
			// After a daemon reconnect the view model is fresh but the window kept its
			// selection — restore it.
			.onAppear {
				if let name = selection, viewModel.selectedName == nil {
					viewModel.select(name: name)
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
			MainVMView(viewModel: viewModel)
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
	}
}

#Preview {
	//VMNavigationView()
}
