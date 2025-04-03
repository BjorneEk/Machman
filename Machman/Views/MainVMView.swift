//
//  MainVMView.swift
//  Machman
//
//  Created by Gustaf Franzen on 2025-03-31.
//

import SwiftUI
struct EditableText: View {
	@Binding var text: String
	let onSubmit: () -> Void
	let onChange: (String) -> Void


	@State private var isEditing = false
	@FocusState private var isFocused: Bool

	init(
		_ text: Binding<String>,
		onSubmit: @escaping () -> Void = { },
		onChange: @escaping (String) -> Void = { _ in }
	) {
		self._text = text
		self.onSubmit = onSubmit
		self.onChange = onChange


	}


	var body: some View {
		Group {
			if isEditing {
				TextField("", text: $text, onCommit: {
					isEditing = false
					onSubmit()
				})
				//.textFieldStyle(.roundedBorder)
				.focused($isFocused)

				.frame(maxWidth: 200)
				.onAppear {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
						isFocused = true
					}
				}
				.onChange(of: text) {
					onChange(text)
				}
			} else {
				Text(text)
					.help("double click to edit")
					.onTapGesture(count: 2) {
						isEditing = true
					}
			}
		}
	}
}

struct MainVMView: View {
	@StateObject private var viewModel: VMListViewModel
	@StateObject var previewViewModel: PreviewViewModel
	@State private var previewWidth: CGFloat = 0

	@State private var vm: VirtualMachine

	@State private var vmName: String


	init(viewModel: @autoclosure @escaping () -> VMListViewModel = VMListViewModel(),
		 selectedItem: VirtualMachine) {
		_viewModel = StateObject(wrappedValue: viewModel())
		vm = selectedItem
		vmName = selectedItem.config.name
		_previewViewModel = StateObject(wrappedValue: PreviewViewModel(vm: selectedItem))

	}
	init() {
		let a  = VMListViewModel()
		_viewModel = StateObject(wrappedValue: a)
		let b = a.vmList().first!
		vm = b
		vmName = b.config.name
		_previewViewModel = StateObject(wrappedValue: PreviewViewModel(vm: b))
	}

	var body: some View {
		VStack {
			HStack {
				PreviewView(viewModel: previewViewModel)
					.frame(minWidth: 170)
				Spacer()
				ConfigVMDisksView(vm: vm)
					.frame(minWidth: 200)
					.frame(minHeight: 250)
			}
			.padding(.vertical, 0)
			Divider()
			HStack {
				ConfigVMView(vm: vm)
					.frame(width: previewWidth)
				ConfigVMHostMountsView(vm: vm)
					.frame(minWidth: 200)
			}
		}
		.onPreferenceChange(PreviewWidthKey.self) { width in
			previewWidth = width
		}
		.toolbar {
			ToolbarItem(placement: .principal) {
				EditableText($vmName)
					.font(.largeTitle)
					//.font(.system(size: 25, weight: .medium, design: .default))
					.onSubmit {
						DispatchQueue.main.async {
							if viewModel.hasVM(vmName) {
								vm.log(error: "A VM named '\(vmName)' already exists.")
								vmName = vm.config.name
							}
							if VMListViewModel.confirmDialog(
								message: "Change VM name",
								informativeText: "Are you shure you want to change the name of: '\(self.vm.config.name)' to '\(vmName)'") {
								do {
									let old = self.vm.config.name
									try self.vm.config.rename(to: vmName)
									vmName = vm.config.name
									if let keyToRemove = viewModel.vmMap.first(where: { $0.key == old })?.key {
										viewModel.vmMap.removeValue(forKey: keyToRemove)
									}
									viewModel.vmMap[old] = nil
									viewModel.vmMap[vmName] = vm
									vm.log(message: "Renamed \(old) to \(self.vm.config.name)")
								} catch {
									vm.log(error: "Failed to rename VM: \(error.localizedDescription)")
								}
							}
							vmName = vm.config.name
						}
					}
			}
			ToolbarItem {
				Button(action: {
					viewModel.run(c: vm.config)
				}) {
					Label(viewModel.runBtnLbl(c: vm.config).running() ? "Stop \(vm.config.name)" : "Run \(vm.config.name)", systemImage: viewModel.runBtnLbl(c: vm.config).rawValue)
				}
				.help(viewModel.runBtnLbl(c: vm.config).running() ? "Stop \(vm.config.name)" : "Run \(vm.config.name)")
			}
			ToolbarItem {
				Button(action: {
					viewModel.delete(vm: vm)
					vm.log(message: "deleted \(vm.config.name)")
				}) {
					Label("Delete", systemImage: "trash")
				}
				.help("delete \(vm.config.name)")
			}
		}
		.padding()
		.background(FocusAndTopmostTracker { focused in
			self.previewViewModel.onFocusEvent(focused: focused)
		})

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
			let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == NSRunningApplication.current.processIdentifier

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
	MainVMView()
}
