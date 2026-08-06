//
//  VMRegistry.swift
//  Machman
//
//  The engine facade: the single authority over which VMs exist and which are running. Owns the
//  event bus and the console presenter; enforces cross-VM invariants (unique names, no
//  delete/rename while running). This is what LocalMachman wraps for the API.
//

import Foundation
import AppKit
import MachmanAPI

// One managed VM: persisted config plus (when running) its live runtime. Class identity is the
// UI selection identity; the registry guarantees one instance per VM.
@MainActor
final class VirtualMachine: NSObject, Identifiable {
	let config: VMConfig
	var runtime: VMRuntime?
	var previewImage: NSImage?
	private weak var events: EventBus?

	init(config: VMConfig, events: EventBus? = nil) {
		self.config = config
		self.events = events
		super.init()
	}

	var state: VMState { runtime?.state ?? .stopped }

	func updatePreview(img: NSImage) {
		previewImage = img
	}

	// EventBus prints every log event once (the console is the guaranteed sink); subscribers
	// and, later, remote clients get the same line as an event.
	func log(error: String) {
		events?.emit(.log(vm: config.name, level: .error, message: error)) ?? print(error)
	}

	func log(message: String) {
		events?.emit(.log(vm: config.name, level: .message, message: message)) ?? print(message)
	}

	func log(warning: String) {
		events?.emit(.log(vm: config.name, level: .warning, message: warning)) ?? print(warning)
	}
}

@MainActor
final class VMRegistry {
	let events = EventBus()
	let presenter = ConsolePresenter()
	private(set) var vms: [String: VirtualMachine] = [:]
	// Sessions live here (not in a view) so a running install keeps its phase and progress
	// when the user navigates away, and a second install of the same VM can't start.
	private var installSessions: [String: InstallSession] = [:]

	init() {
		presenter.stopHandler = { [weak self] name, mode in
			guard let self = self, let vm = self.vms[name] else { return }
			Task {
				do {
					try await self.stop(vm, mode: mode)
				} catch {
					vm.log(error: "Failed to stop VM: \(name): \(error)")
				}
			}
		}
		presenter.isRunning = { [weak self] name in
			self?.vms[name]?.state.isRunning ?? false
		}
		scan()
	}

	private func scan() {
		let folderURL = URL(fileURLWithPath: machmanVMDir)
		do {
			let contents = try FileManager.default.contentsOfDirectory(
				at: folderURL, includingPropertiesForKeys: [.isDirectoryKey],
				options: [.skipsHiddenFiles])
			for url in contents {
				let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
				guard values?.isDirectory ?? false else { continue }
				let name = url.lastPathComponent
				guard let config = try? VMConfig(name: name) else { continue }
				vms[name] = VirtualMachine(config: config, events: events)
			}
		} catch {
			print("Error reading machines: \(error)")
		}
	}

	func list() -> [VirtualMachine] {
		vms.values.sorted {
			$0.config.lastRan ?? .distantPast > $1.config.lastRan ?? .distantPast
		}
	}

	func vm(named name: String) -> VirtualMachine? {
		vms[name]
	}

	// MARK: - Run / stop

	func start(_ vm: VirtualMachine, openConsole: Bool = true) async throws {
		guard vm.runtime == nil else {
			throw VirtualMachineError.critical("\(vm.config.name) is already running")
		}
		guard !(installSessions[vm.config.name]?.isInstalling ?? false) else {
			throw VirtualMachineError.critical(
				"(\(vm.config.name)) cannot start while macOS is installing")
		}
		let runtime = VMRuntime(config: vm.config, events: events)
		runtime.onTeardown = { [weak self, weak vm] in
			guard let vm = vm else { return }
			vm.runtime = nil
			self?.presenter.dropConsole(name: vm.config.name)
		}
		vm.runtime = runtime
		do {
			try await runtime.start()
		} catch {
			vm.runtime = nil
			throw error
		}
		try? vm.config.markRan()
		if openConsole, let vz = runtime.vz {
			presenter.openConsole(name: vm.config.name, vz: vz)
		}
	}

	func stop(_ vm: VirtualMachine, mode: StopMode) async throws {
		guard let runtime = vm.runtime else { return }
		switch mode {
		case .soft:
			try runtime.requestSoftStop()
		case .force:
			try await runtime.forceStop()
			vm.log(message: "VM: \(vm.config.name) stopped successfully.")
		}
	}

	func openConsole(_ vm: VirtualMachine) {
		guard let vz = vm.runtime?.vz else { return }
		presenter.openConsole(name: vm.config.name, vz: vz)
	}

	func captureImage(name: String) async -> NSImage {
		await presenter.captureImage(name: name)
	}

	// MARK: - Create / delete / rename

	func create() throws -> VirtualMachine {
		var nbr = 1
		while vms["new-VM\(nbr)"] != nil {
			nbr += 1
		}
		let name = "new-VM\(nbr)"
		try VMConfig.createNewVMDirectory(name: name)
		let vm = VirtualMachine(
			config: try VMConfig(
				name: name, memorySize: 4, cpuCount: VMConfig.computeMaxCPUCount()),
			events: events)
		vms[name] = vm
		events.emit(.listChanged)
		return vm
	}

	func delete(_ vm: VirtualMachine) throws {
		let name = vm.config.name
		guard vm.runtime == nil else {
			throw VirtualMachineError.critical("stop \(name) before deleting it")
		}
		guard !(installSessions[name]?.isInstalling ?? false) else {
			throw VirtualMachineError.critical("wait for the macOS install to finish first")
		}
		presenter.dropConsole(name: name)
		vms[name] = nil
		installSessions[name] = nil
		try VMConfig.deleteVMDirectory(name: name)
		events.emit(.listChanged)
	}

	func rename(_ vm: VirtualMachine, to newName: String) throws {
		let oldName = vm.config.name
		guard oldName != newName else { return }
		guard vms[newName] == nil else {
			throw VirtualMachineError.critical("a VM named '\(newName)' already exists")
		}
		guard vm.runtime == nil else {
			throw VirtualMachineError.critical("stop \(oldName) before renaming it")
		}
		try vm.config.rename(to: newName)
		vms[oldName] = nil
		vms[newName] = vm
		if let session = installSessions.removeValue(forKey: oldName) {
			installSessions[newName] = session
		}
		events.emit(.listChanged)
	}

	// MARK: - macOS install sessions

	func installSession(for vm: VirtualMachine) -> InstallSession {
		if let existing = installSessions[vm.config.name] {
			return existing
		}
		let session = InstallSession(
			config: vm.config, events: events,
			isVMRunning: { [weak vm] in vm?.state.isRunning ?? false })
		installSessions[vm.config.name] = session
		return session
	}

	func isInstalling(_ vm: VirtualMachine) -> Bool {
		installSessions[vm.config.name]?.isInstalling ?? false
	}
}
