//
//  NewMainView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-31.
//

import SwiftUI

struct NewMainView: View {
	@StateObject var viewModel = NewVMListViewModel()
	@State private var selectedItem: VirtualMachine?
	@State private var navigate = false

	var body: some View {
		VStack(spacing: 0) {
			// MARK: Header
			Text("My Application")
				.font(.largeTitle)
				.frame(maxWidth: .infinity)
				.padding()
				.background(Color.gray.opacity(0.2))

			// MARK: Middle Section with Sidebar
			ZStack(alignment: .leading) {
				HStack(spacing: 0) {
					List {
						ForEach(viewModel.vmList(), id: \.config.name) { component in
							HStack {
								if viewModel.runBtnLbl(c: component.config).running() {
									VMActionButton(
										systemImageName: "pc",
										tooltip: "Info \(component.config.name)",
										color: .blue,
										action: {
											selectedItem = component
										}
									)
									.font(.system(size: 25, weight: .medium, design: .default))
								} else {
									VMActionButton(
										systemImageName: "pause.fill",
										tooltip: "Info \(component.config.name)",
										action: {
											selectedItem = component
										}
									)
									.font(.system(size: 25, weight: .medium, design: .default))
								}

								Text(component.config.name)
									.font(.system(size: 25, weight: .medium, design: .default))
								Spacer()


							}
						}
					}
					Spacer()
				}

				// Slide-over Panel
				
			}
			.frame(height: 250)
			Divider()
			// MARK: Log Section
			Table(viewModel.log) {
				TableColumn("Type") { (entry: VirtualMachineLog) in
					switch entry {
					case .message: Text("Message")
					case .warning: Text("Warning")
					case .error: Text("Error")
					}
				}
				TableColumn("Message") { (entry: VirtualMachineLog) in
					switch entry {
					case	.message(let msg),
						.warning(let msg),
						.error(let msg):
							Text(msg)
					}
				}
			}
			.frame(minHeight: 200)
		}
		.animation(.easeInOut, value: selectedItem)
	}
}

#Preview {
	NewMainView()
}
