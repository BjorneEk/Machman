//
//  VMListViewModel.swift
//  Machman
//
//  The client half of the app: view-facing state fed exclusively through MachmanControlling
//  and its event stream. Holds no engine objects — only DTOs, selection, preview images, and
//  install-phase snapshots. Works identically against LocalMachman (in-process) or a future
//  RemoteMachman (daemon).
//

import Foundation
import AppKit
import SwiftUI
import MachmanUI
import MachmanAPI

// One user-facing failure: title = what the user was doing, message = why it failed.
struct PresentedError: Identifiable {
	let id = UUID()
	let title: String
	let message: String
}

enum RunBtnState {
	case run
	case stop

	static func fromVMState(s: VMState) -> RunBtnState {
		return s.isRunning ? .stop : .run
	}
	var symbol: String {
		switch self {
		case .run: return MachmanSymbols.start
		case .stop: return MachmanSymbols.forceStop
		}
	}
	func running() -> Bool {
		return self == .stop
	}
}

@MainActor
final class VMListViewModel: ObservableObject {
	let api: MachmanControlling
	@Published private(set) var vms: [VMInfo] = []
	@Published private(set) var capabilities: HostCapabilities?
	@Published private(set) var installPhases: [String: InstallPhase] = [:]
	@Published private(set) var previews: [String: NSImage] = [:]
	@Published var selectedName: String? = nil
	@Published var vmName: String = ""
	@Published var presentedError: PresentedError?
	// Binding surface for .alert(isPresented:presenting:) — clears the item on dismiss.
	var isErrorPresented: Bool {
		get { presentedError != nil }
		set { if !newValue { presentedError = nil } }
	}

	private var isFocused = true
	private let previewInterval: Double = 4
	private var previewTask: Task<Void, Never>?
	private var eventTask: Task<Void, Never>?

	var selected: VMInfo? {
		selectedName.flatMap { name in vms.first { $0.name == name } }
	}

	init(api: MachmanControlling) {
		self.api = api
		eventTask = Task { [weak self] in
			guard let api = self?.api else { return }
			let stream = await api.events()
			await self?.reload()
			for await event in stream {
				guard let self = self else { return }
				await self.handle(event: event)
			}
		}
	}

	deinit {
		eventTask?.cancel()
		previewTask?.cancel()
	}

	func reload() async {
		if let list = try? await api.listVMs() {
			vms = list
		}
		if capabilities == nil {
			capabilities = try? await api.hostCapabilities()
		}
		for vm in vms where vm.boot.mode == .macOS && installPhases[vm.name] == nil {
			if let phase = try? await api.macInstallPhase(vm: vm.name) {
				installPhases[vm.name] = phase
			}
		}
	}

	private func handle(event: VMEvent) async {
		switch event {
		case .stateChanged(let name, let state):
			if let index = vms.firstIndex(where: { $0.name == name }) {
				vms[index].state = state
			}
			if name == selectedName {
				restartPreviewLoop()
			}
		case .listChanged:
			await reload()
		case .installPhaseChanged(let name, let phase):
			installPhases[name] = phase
		case .log(let vm, let level, let message):
			// The engine logs these in its own process too, but that process is auto-launched —
			// relaying through the client's logger keeps engine warnings visible from the app
			// the user actually runs.
			MachmanLogger.log(level.logType, "\(vm.map { "(\($0)) " } ?? "")\(message)")
		case .unknown:
			break
		}
	}

	func log(message: String) {
		MachmanLogger.log(.log, message)
	}

	// MARK: - Error surface

	// Alerts always log first: the unified log keeps the record even if the alert is
	// dismissed unread.
	func present(message: String, while action: String) {
		MachmanLogger.log(.interactionError, "\(action) failed: \(message)")
		presentedError = PresentedError(title: "\(action) failed", message: message)
	}

	func present(_ error: Error, while action: String) {
		present(message: Self.message(for: error), while: action)
	}

	// localizedDescription on a non-LocalizedError is NSError-bridge boilerplate ("The
	// operation couldn't be completed…"); String(describing:) picks up the connection
	// errors' CustomStringConvertible instead.
	private static func message(for error: Error) -> String {
		(error as? LocalizedError)?.errorDescription ?? String(describing: error)
	}

	// MARK: - Install phases

	func installPhase(for vm: VMInfo) -> InstallPhase {
		if let phase = installPhases[vm.name] {
			return phase
		}
		guard vm.boot.mode == .macOS, let state = vm.boot.macInstallState else {
			return InstallPhase(kind: .idle)
		}
		switch state.kind {
		case .installed:
			return InstallPhase(kind: .installed)
		case .failed:
			return InstallPhase(kind: .failed, message: state.message)
		case .installing, .interrupted:
			// No live session known client-side means a past install was cut short.
			return InstallPhase(kind: .interrupted)
		}
	}

	func isInstalling(_ vm: VMInfo) -> Bool {
		switch installPhase(for: vm).kind {
		case .resolving, .downloading, .installing:
			return true
		case .idle, .installed, .failed, .interrupted:
			return false
		}
	}

	// MARK: - Preview

	func preview() -> NSImage? {
		selectedName.flatMap { previews[$0] }
	}

	func isLoading() -> Bool {
		guard let vm = selected else { return false }
		return vm.state.isRunning && preview() == nil
	}

	func onFocusEvent(focused: Bool) {
		isFocused = focused
		restartPreviewLoop()
	}

	private func restartPreviewLoop() {
		previewTask?.cancel()
		previewTask = nil
		guard isFocused, let vm = selected, vm.state.isRunning else { return }
		let name = vm.name
		previewTask = Task { [weak self] in
			while !Task.isCancelled {
				guard let self = self, self.selectedName == name else { return }
				let data = try? await self.api.preview(vm: name, maxWidth: 1280)
				if Task.isCancelled { return }
				if let data = data, let image = NSImage(data: data) {
					self.previews[name] = image
				}
				try? await Task.sleep(for: .seconds(self.previewInterval))
			}
		}
	}

	// MARK: - List / selection

	func runBtnLbl(vm: VMInfo) -> RunBtnState {
		return RunBtnState.fromVMState(s: vm.state)
	}

	func hasVM(_ name: String) -> Bool {
		vms.contains { $0.name == name }
	}

	func select(name: String?) {
		selectedName = name
		vmName = name ?? ""
		restartPreviewLoop()
	}

	// MARK: - Actions

	func toggleRun(_ vm: VMInfo) {
		if vm.state.isRunning {
			stopVM(vm.name)
		} else {
			startVM(vm.name)
		}
	}

	func startVM(_ name: String, headless: Bool = false) {
		Task { [weak self] in
			do {
				try await self?.api.start(
					vm: name, options: StartOptions(openConsole: !headless))
			} catch {
				self?.present(error, while: "Starting \(name)")
			}
		}
	}

	func openConsole(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.openConsole(vm: name)
			} catch {
				self?.present(error, while: "Opening the \(name) console")
			}
		}
	}

	func closeConsole(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.closeConsole(vm: name)
			} catch {
				self?.present(error, while: "Closing the \(name) console")
			}
		}
	}

	func stopVM(_ name: String, mode: StopMode = .force) {
		Task { [weak self] in
			do {
				try await self?.api.stop(vm: name, mode: mode)
			} catch {
				self?.present(error, while: "Stopping \(name)")
			}
		}
	}

	func createVM() async -> String? {
		do {
			let vm = try await api.createVM()
			await reload()
			return vm.name
		} catch {
			present(error, while: "Creating a VM")
			return nil
		}
	}

	func deleteVM(_ vm: VMInfo) {
		if !VMListViewModel.confirmDialog(
			message: "Delete \(vm.name)?",
			informativeText: "Are you sure you want to delete \(vm.name)? "
				+ "This action cannot be undone.") {
			return
		}
		Task { [weak self] in
			do {
				try await self?.api.deleteVM(named: vm.name)
				self?.select(name: nil)
			} catch {
				self?.present(error, while: "Deleting \(vm.name)")
			}
		}
	}

	func rename(from oldName: String, to newName: String) async -> Bool {
		do {
			try await api.renameVM(named: oldName, to: newName)
			await reload()
			select(name: newName)
			if let image = previews.removeValue(forKey: oldName) {
				previews[newName] = image
			}
			return true
		} catch {
			present(error, while: "Renaming \(oldName)")
			vmName = oldName
			return false
		}
	}

	func setHardware(_ name: String, cpuCount: Int? = nil, memoryBytes: UInt64? = nil) {
		Task { [weak self] in
			do {
				try await self?.api.setHardware(
					vm: name, cpuCount: cpuCount, memoryBytes: memoryBytes)
			} catch {
				self?.present(error, while: "Updating hardware for \(name)")
			}
		}
	}

	func clampMemory(_ bytes: UInt64, floor: UInt64) -> UInt64 {
		ByteSize.clampMemory(bytes, floor: floor, capabilities: capabilities)
	}

	func addDisk(_ name: String, _ disk: NewDisk) {
		Task { [weak self] in
			do {
				try await self?.api.addDisk(vm: name, disk)
			} catch {
				self?.present(error, while: "Adding a disk")
			}
		}
	}

	func removeDisk(_ name: String, diskID: String) {
		Task { [weak self] in
			do {
				try await self?.api.removeDisk(vm: name, diskID: diskID)
			} catch {
				self?.present(error, while: "Removing a disk")
			}
		}
	}

	func addMount(_ name: String, path: String, tag: String) {
		Task { [weak self] in
			do {
				try await self?.api.addMount(vm: name, path: path, tag: tag)
			} catch {
				self?.present(error, while: "Adding a mount point")
			}
		}
	}

	func removeMount(_ name: String, mountID: String) {
		Task { [weak self] in
			do {
				try await self?.api.removeMount(vm: name, mountID: mountID)
			} catch {
				self?.present(error, while: "Removing a mount point")
			}
		}
	}

	func setKernelBoot(_ name: String, enabled: Bool) async -> Bool {
		do {
			try await api.setKernelBoot(vm: name, enabled: enabled)
			return true
		} catch {
			present(error, while: "Switching boot mode")
			return false
		}
	}

	func updateKernelSettings(_ name: String, _ settings: KernelSettings) {
		Task { [weak self] in
			do {
				try await self?.api.updateKernelSettings(vm: name, settings)
			} catch {
				self?.present(error, while: "Saving kernel settings")
			}
		}
	}

	func startInstall(_ name: String, source: InstallSource) {
		Task { [weak self] in
			do {
				try await self?.api.startMacInstall(vm: name, source: source)
			} catch {
				self?.present(error, while: "Starting the macOS install")
			}
		}
	}

	func cancelInstall(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.cancelMacInstall(vm: name)
			} catch {
				self?.present(error, while: "Canceling the macOS install")
			}
		}
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
}
