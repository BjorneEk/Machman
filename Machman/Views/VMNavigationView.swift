//
//  VMNavigationView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-31.
//

import SwiftUI
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
				//.frame(width: bSize, height: bSize)
				.imageScale(.large)
				.foregroundColor(color)
				.aspectRatio(1, contentMode: .fit)
				.font(.largeTitle)
				//.font(weight: .medium))
				//.font(.system(size: fSize, weight: .medium))
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
	var bSize: CGFloat = 20
	var fSize: CGFloat = 20

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

struct VMNavigationView: View {
	@StateObject var viewModel = VMListViewModel()
	@State private var navigate = false
	@Binding private var selection: VirtualMachine?

	init(viewModel: VMListViewModel = VMListViewModel(), selection: Binding<VirtualMachine?>) {
		_viewModel = StateObject(wrappedValue: viewModel)
		self._selection = selection
	}

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
				viewModel.select(vm: selection)
				navigate = !navigate
			}
			Button(action:{
				selection = viewModel.addNewVM()
				viewModel.select(vm: selection)
			}) {
				HStack {
					Image(systemName: "plus")
					Text("New VM")
				}
			}
			.buttonStyle(.borderless)
			.padding()
		} detail: {
			// Detail View
			//if let selected = selection {
				MainVMView(viewModel: viewModel)
					.onAppear {print("---Selected VM: \(selection?.config.name ?? "none")")}
					.id(navigate)
			/*} else {
				Text("Select a VM")
					.font(.title)
					.foregroundColor(.secondary)
			}*/
		}
	}
	
}

#Preview {
	//VMNavigationView()
}
