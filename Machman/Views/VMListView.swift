//
//  VMListView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-29.
//

import SwiftUI

var vmWindows: [String: NSWindow] = [:]
//var compBtnSize: CGFloat = 32
//var compBtnFontSize: CGFloat = 20
var compBtnSize: CGFloat = 15
var compBtnFontSize: CGFloat = 10
protocol VMActionView: View {
	var systemImageName: String { get }
	var color: Color { get }

	func label(bSize: CGFloat, fSize: CGFloat) -> AnyView
	func hoverHandler() -> (Bool) -> Void
}

extension VMActionView {
	func label(bSize: CGFloat, fSize: CGFloat) -> AnyView {
		AnyView(
			Image(systemName: systemImageName)
				.frame(width: bSize, height: bSize)
				.imageScale(.large)
				.foregroundColor(color)
				.font(.system(size: fSize, weight: .medium))
		)
	}

	func hoverHandler() -> (Bool) -> Void {
		return { hovering in
			if hovering {
				NSCursor.pointingHand.push()
			} else {
				NSCursor.pop()
			}
		}
	}
}

struct VMActionButton: VMActionView {
	
	let systemImageName: String
	let color: Color
	let action: () -> Void
	let tooltip: String
	var bSize: CGFloat = compBtnSize
	var fSize: CGFloat = compBtnFontSize

	init(systemImageName: String, tooltip: String, color: Color = .primary, action: @escaping () -> Void) {
		self.systemImageName = systemImageName
		self.color = color
		self.action = action
		self.tooltip = tooltip
	}
	init(systemImageName: String, tooltip: String, bSize: CGFloat, fSize: CGFloat, color: Color = .primary, action: @escaping () -> Void) {
		self.systemImageName = systemImageName
		self.color = color
		self.action = action
		self.tooltip = tooltip
		self.bSize = bSize
		self.fSize = fSize
	}

	var body: some View {
		Button(action: action) {
			label(bSize: bSize, fSize: fSize)
		}
		.onHover(perform: hoverHandler())
		.buttonStyle(.borderless)
		.contentShape(Rectangle())
		.help(self.tooltip)
	}
}

struct VMListView: View {
	@StateObject var viewModel = VMListViewModel()
	@State private var navigate = false
	@State private var selected: VMConfig?

	var body: some View {
		NavigationStack {
			VStack {
				// Header: Label and "Add New" button
				
				HStack {
					Text("Machines")
						.font(.system(size: 35, weight: .medium, design: .default))
					Spacer()
					/*NavigationLink(destination: NewVMView(viewModel: viewModel)) {
						Image(systemName: "plus")
							.font(.system(size: 35, weight: .medium, design: .default))
					}
					.buttonStyle(.plain)
					.contentShape(Rectangle())
					.help("Add new virtual machine")
					.onHover { hovering in
						if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
					}
					 */
				}
				.padding()
				// List of components with three buttons each.
				List {
					ForEach(viewModel.vmList(), id: \.config.name) { component in
						HStack {
							if viewModel.runBtnLbl(c: component.config).running() {
								Image(systemName: "pc")
									.foregroundColor(.blue)
									.font(.system(size: 25, weight: .medium, design: .default))
							} else {
								Image(systemName: "pause.fill")
									.font(.system(size: 25, weight: .medium, design: .default))
							}

							Text(component.config.name)
								.font(.system(size: 25, weight: .medium, design: .default))
							Spacer()

							VMActionButton(systemImageName: "trash", tooltip: "Delete \(component.config.name)", action: {
								viewModel.delete(c: component.config)
							})

							VMActionButton(systemImageName: "gear", tooltip: "Configure \(component.config.name)", action: {
								navigate = true
								selected = component.config
							})

							VMActionButton(
								systemImageName: "hammer",
								tooltip: "Build \(component.config.name)",
								color: .yellow,
								action: {
								viewModel.build(c: component.config)
							})

							VMActionButton(
								systemImageName: viewModel.runBtnLbl(c: component.config).rawValue,
								tooltip: viewModel.runBtnLbl(c: component.config).running() ? "Stop \(component.config.name)" : "Run \(component.config.name)",
								color: viewModel.runBtnLbl(c: component.config).color(),
								action: {
								viewModel.run(c: component.config)
							})
						}
					}
				}.navigationDestination(isPresented: $navigate) {
					if let config = selected {
						ConfigureVMView(viewModel: viewModel, config: config)
					}
				}
			}
		}
	}
}

#Preview {
	VMListView()
}
