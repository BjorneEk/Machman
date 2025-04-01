//
//  VMNavigationView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-31.
//

import SwiftUI

struct VMNavigationView: View {
	@StateObject var viewModel = NewVMListViewModel()
	@State private var navigate = false
	@State private var selection: VirtualMachine?


	var body: some View {
		NavigationSplitView {
			List(selection: $selection) {
				ForEach(viewModel.vmList(), id: \.id) { item in
					HStack {
						Image(systemName: viewModel.runBtnLbl(c: item.config).running() ? "pc" : "pause.fill")
							.foregroundColor(viewModel.runBtnLbl(c: item.config).running() ? .blue : .primary)
						Text(item.config.name)
							.font(.callout)
						Spacer()
					}
					.tag(item)
				}
			}
			.onChange(of: selection) {
				print("Selected VM: \(selection?.config.name ?? "none")")
				navigate = !navigate
			}
			Button(action:{
				selection = viewModel.addNewVM()
			}) {
				HStack {
					Image(systemName: "plus")
					Text("New VM")
				}
			}
			.buttonStyle(.borderless)
			.padding()
		} detail: {
			// 🧱 Detail View
			if let selected = selection {
				MainVMView(viewModel: viewModel, selectedItem: selected)
					.onAppear {print("---Selected VM: \(selection?.config.name ?? "none")")}
					.id(navigate)
			} else {
				Text("Select a VM")
					.font(.title)
					.foregroundColor(.secondary)
			}
		}
	}
}

#Preview {
	VMNavigationView()
}
