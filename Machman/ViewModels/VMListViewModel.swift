//
//  VMListViewModel.swift
//  Machman
//
//  View-facing state over VMRegistry: selection, previews, install-controller cache, and the
//  UI verbs the views call. Engine work (starting, stopping, windows) lives in the registry;
//  this class reacts to its event stream.
//

import Foundation
import AppKit
import SwiftUI
import MachmanAPI

enum RunBtnState: String {
	case run  = "play.circle"
	case stop = "stop.circle"

	static func fromVMState(s: VMState) -> RunBtnState {
		return s.isRunning ? .stop : .run
	}
	func color() -> Color {
		switch self {
		case .run:
			return .green
		case .stop:
			return .red
		}
	}
	func running() -> Bool {
		return self == .stop
	}
}

@MainActor
class VMListViewModel: ObservableObject {
	let registry: VMRegistry
	@Published var selected: VirtualMachine? = nil
	@Published var vmName: String = ""
	@Published private var previewImage: NSImage?

	private var isFocused = true
	private let previewInterval: Double = 4
	private var previewTask: Task<Void, Never>?
	private var eventTask: Task<Void, Never>?

	// Install controllers live here (not in a view) so a running install keeps its phase and
	// live progress when the user navigates between VMs, and so a second install of the same
	// VM can't be started from a fresh pane.
	private var macInstallControllers: [String: MacInstallController] = [:]

	init(registry: VMRegistry? = nil) {
		self.registry = registry ?? VMRegistry()
		eventTask = Task { [weak self] in
			guard let stream = self?.registry.events.stream() else { return }
			for await event in stream {
				guard let self = self else { return }
				self.handle(event: event)
			}
		}
	}

	deinit {
		eventTask?.cancel()
		previewTask?.cancel()
	}

	private func handle(event: VMEvent) {
		if case .stateChanged(let vm, _) = event, vm == selected?.config.name {
			restartPreviewLoop()
		}
		// Coarse refresh, replacing the old forceUpdate() back-pointer pokes from the engine.
		objectWillChange.send()
	}

	func installController(for vm: VirtualMachine) -> MacInstallController {
		if let existing = macInstallControllers[vm.config.name] {
			return existing
		}
		let controller = MacInstallController(vm: vm, listViewModel: self)
		macInstallControllers[vm.config.name] = controller
		return controller
	}

	func isInstalling(_ vm: VirtualMachine) -> Bool {
		macInstallControllers[vm.config.name]?.isInstalling ?? false
	}

	private func rekeyInstallController(from old: String, to new: String) {
		if let controller = macInstallControllers.removeValue(forKey: old) {
			macInstallControllers[new] = controller
		}
	}

	// Until a log-viewer UI exists, the console is the only place errors are guaranteed visible.
	func log(error: String) {
		print(error)
	}

	func log(message: String) {
		print(message)
	}

	func log(warning: String) {
		print(warning)
	}

	// MARK: - Preview

	func preview() -> NSImage? {
		return (self.previewImage ?? self.selected?.previewImage)
	}

	func isLoading() -> Bool {
		guard let vm = self.selected else { return false }
		return vm.state.isRunning && self.previewImage == nil
	}

	func onFocusEvent(focused: Bool) {
		self.isFocused = focused
		restartPreviewLoop()
	}

	private func restartPreviewLoop() {
		previewTask?.cancel()
		previewTask = nil
		guard isFocused, let vm = selected, vm.state.isRunning else { return }
		let name = vm.config.name
		previewTask = Task { [weak self] in
			while !Task.isCancelled {
				guard let self = self, self.selected?.config.name == name else { return }
				let image = await self.registry.captureImage(name: name)
				if Task.isCancelled { return }
				self.previewImage = image
				self.selected?.updatePreview(img: image)
				try? await Task.sleep(for: .seconds(self.previewInterval))
			}
		}
	}

	// MARK: - List / selection

	func vmList() -> [VirtualMachine] {
		registry.list()
	}

	func runBtnLbl(vm: VirtualMachine) -> RunBtnState {
		return RunBtnState.fromVMState(s: vm.state)
	}

	func forceUpdate() {
		self.objectWillChange.send()
	}

	func hasVM(_ name: String) -> Bool {
		return registry.vm(named: name) != nil
	}

	func select(vm: VirtualMachine?) {
		self.selected = vm
		self.vmName = vm?.config.name ?? ""
		self.previewImage = vm?.previewImage
		restartPreviewLoop()
	}

	// MARK: - Actions

	func run(c: VMConfig) {
		guard let vm = registry.vm(named: c.name) else {
			log(error: "no VM named \(c.name)")
			return
		}
		if vm.state.isRunning {
			Task { [weak self] in
				do {
					try await self?.registry.stop(vm, mode: .force)
				} catch {
					vm.log(error: "Failed to stop VM: \(vm.config.name): \(error)")
				}
				self?.forceUpdate()
			}
		} else {
			if isInstalling(vm) {
				log(error: "(\(vm.config.name)) cannot start while macOS is installing")
				return
			}
			Task { [weak self] in
				do {
					try await self?.registry.start(vm, openConsole: true)
				} catch {
					vm.log(error: "(\(vm.config.name)) \(error)")
				}
				self?.forceUpdate()
			}
		}
	}

	func rename(vm: VirtualMachine, to newName: String) throws {
		let oldName = vm.config.name
		try registry.rename(vm, to: newName)
		rekeyInstallController(from: oldName, to: newName)
		self.vmName = vm.config.name
	}

	static func confirmDialog(message: String, informativeText: String) -> Bool {
		let alert = NSAlert()
		alert.messageText = message
		alert.informativeText = informativeText
		alert.alertStyle = .warning
		alert.addButton(withTitle: "OK")
		alert.addButton(withTitle: "Cancel")

		let response = alert.runModal()
		return response == .alertFirstButtonReturn
	}

	func delete(vm: VirtualMachine) {
		if !VMListViewModel.confirmDialog(
			message: "Delete \(vm.config.name)?",
			informativeText: "Are you sure you want to delete \(vm.config.name)? "
				+ "This action cannot be undone.") {
			return
		}

		do {
			try registry.delete(vm)
		} catch {
			log(error: "Failed to delete \(vm.config.name): \(error)")
			return
		}
		macInstallControllers[vm.config.name] = nil
		self.selected = nil
		forceUpdate()
	}

	func addNewVM() -> VirtualMachine? {
		do {
			return try registry.create()
		} catch {
			log(error: "Failed to create VM: \(error)")
			return nil
		}
	}
}
