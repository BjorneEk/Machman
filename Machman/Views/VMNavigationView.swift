//
//  VMNavigationView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-31.
//

import SwiftUI
import MachmanAPI

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
				.imageScale(.large)
				.foregroundColor(color)
				.aspectRatio(1, contentMode: .fit)
				.font(.largeTitle)
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
