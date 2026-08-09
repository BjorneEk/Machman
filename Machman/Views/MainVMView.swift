//
//  MainVMView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-31.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct MainVMView: View {
	@StateObject private var viewModel: VMListViewModel
	@State private var previewWidth: CGFloat = 0

	init(viewModel: VMListViewModel) {
		_viewModel = StateObject(wrappedValue: viewModel)
	}

	var body: some View {
		if let vm = viewModel.selected {
			VStack {
				HStack {
					PreviewView(viewModel: viewModel)
						.frame(minWidth: 170)
					Spacer()
					ConfigVMDisksView(vm: vm, viewModel: viewModel)
						.frame(minWidth: 200)
						.frame(minHeight: 250)
				}
				.padding(.vertical, 0)
				Divider()
				// Top-aligned: the two columns have different vertical greed (the left ends in
				// a Spacer, the right doesn't), so center alignment let the mounts box drift.
				HStack(alignment: .top) {
					ConfigVMView(vm: vm, viewModel: viewModel)
						.frame(width: previewWidth)
					ConfigVMHostMountsView(vm: vm, viewModel: viewModel)
						.frame(minWidth: 200)
						.frame(maxHeight: .infinity, alignment: .top)
				}
			}
			.onPreferenceChange(PreviewWidthKey.self) { width in
				previewWidth = width
			}
			.toolbar {
				ToolbarItem(placement: .principal) {
					EditableText($viewModel.vmName)
						.font(.largeTitle)
						.onSubmit {
							let newName = viewModel.vmName
							guard newName != vm.name else { return }
							if viewModel.hasVM(newName) {
								viewModel.present(
									message: "A VM named '\(newName)' already exists.",
									while: "Renaming \(vm.name)")
								viewModel.vmName = vm.name
								return
							}
							if VMListViewModel.confirmDialog(
								message: "Change VM name",
								informativeText: "Are you shure you want to change the name of: "
									+ "'\(vm.name)' to '\(newName)'") {
								Task {
									if await viewModel.rename(from: vm.name, to: newName) {
										viewModel.log(message: "Renamed \(vm.name) to \(newName)")
									}
								}
							} else {
								viewModel.vmName = vm.name
							}
						}
				}
				ToolbarItem {
					Button(action: {
						viewModel.toggleRun(vm)
					}) {
						Label(
							viewModel.runBtnLbl(vm: vm).running()
								? "Stop \(vm.name)" : "Run \(vm.name)",
							systemImage: viewModel.runBtnLbl(vm: vm).symbol)
					}
					.disabled(viewModel.isInstalling(vm))
					.help(viewModel.isInstalling(vm)
						? "macOS is installing; wait for it to finish"
						: (viewModel.runBtnLbl(vm: vm).running()
							? "Stop \(vm.name)"
							: "Run \(vm.name)"
								+ ((vm.startPolicy ?? StartPolicy()).windowed
									? "" : " (headless)")))
				}
				ToolbarItem {
					Button(action: {
						viewModel.deleteVM(vm)
					}) {
						Label("Delete", systemImage: MachmanSymbols.delete)
					}
					.help("delete \(vm.name)")
				}
			}
			.padding()
			.background(FocusAndTopmostTracker { focused in
				self.viewModel.onFocusEvent(focused: focused)
			})
		} else {
			Text("Select a VM")
				.font(.title)
				.foregroundColor(.secondary)
		}
	}
}
struct FocusAndTopmostTracker: NSViewRepresentable {
	let onChange: (Bool) -> Void

	class Coordinator: NSObject {
		weak var window: NSWindow?
		var onChange: (Bool) -> Void
		var lastState: Bool = false
		var checkTimer: Timer?

		init(onChange: @escaping (Bool) -> Void) {
			self.onChange = onChange
		}

		func attach(to window: NSWindow) {
			self.window = window

			NotificationCenter.default.addObserver(self,
				selector: #selector(updateFocusState),
				name: NSWindow.didBecomeKeyNotification,
				object: window)

			NotificationCenter.default.addObserver(self,
				selector: #selector(updateFocusState),
				name: NSWindow.didResignKeyNotification,
				object: window)

			startChecking()
		}

		@objc func updateFocusState() {
			checkState()
		}

		func startChecking() {
			checkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
				self.checkState()
			}
		}

		func checkState() {
			guard let window = window else { return }
			let isKey = window.isKeyWindow
			let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
				== NSRunningApplication.current.processIdentifier

			let currentState = isKey && isFrontmost
			if currentState != lastState {
				lastState = currentState
				onChange(currentState)
			}
		}

		deinit {
			checkTimer?.invalidate()
		}
	}

	func makeCoordinator() -> Coordinator {
		return Coordinator(onChange: onChange)
	}

	func makeNSView(context: Context) -> NSView {
		let view = NSView()
		DispatchQueue.main.async {
			if let window = view.window ?? NSApp.windows.first {
				context.coordinator.attach(to: window)
				context.coordinator.checkState()
			}
		}
		return view
	}



	func updateNSView(_ nsView: NSView, context: Context) {}
}


#Preview {
}
