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

	var body: some View {
		NavigationView {
			VStack {
				List {
					NavigationLink(destination: NewVMView(viewModel: viewModel)) {

						Image(systemName: "plus")
							.font(.system(size: 20))
							.foregroundColor(.green)
							.padding(.leading)
						Text("New VM")
							.font(.system(size: 20))
					}
					.buttonStyle(.plain)
					.help("Add new virtual machine")
					.onHover { hovering in
						if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
					}
					ForEach(viewModel.vmList(), id: \.config.name) { item in
						NavigationLink(destination: MainVMView(viewModel: viewModel, selectedItem: item)) {
							HStack {
								if viewModel.runBtnLbl(c: item.config).running() {
									Image(systemName: "pc")
										.foregroundColor(.blue)
										.font(.system(size: 25, weight: .medium, design: .default))
								} else {
									Image(systemName: "pause.fill")
										.font(.system(size: 25, weight: .medium, design: .default))
								}
								Text(item.config.name)
									.font(.system(size: 15, weight: .medium, design: .default))
								Spacer()
							}
						}
					}
				}
				.listStyle(PlainListStyle())
			}
		}
	}
}

#Preview {
	VMNavigationView()
}
