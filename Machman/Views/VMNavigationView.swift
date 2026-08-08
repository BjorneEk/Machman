//
//  VMNavigationView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-31.
//

import SwiftUI
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
						Image(systemName: item.state.isRunning ? "pc" : "pause.fill")
							.foregroundColor(item.state.isRunning ? .blue : .primary)
						Text(item.name)
							.font(.callout)
						Spacer()
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
					Image(systemName: "plus")
					Text("New VM")
				}
			}
			.buttonStyle(.borderless)
			.padding()
		} detail: {
			MainVMView(viewModel: viewModel)
				.id(navigate)
		}
	}
}

#Preview {
	//VMNavigationView()
}
