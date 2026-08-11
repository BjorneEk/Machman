//
//  VMListViewModel.swift
//  MachmanDesktop
//
//  The client half of the app: view-facing state fed exclusively through MachmanControlling
//  and its event stream. Holds no engine objects — only DTOs, selection, preview images, and
//  install-phase snapshots. Works identically against LocalMachman (in-process) or a future
//  RemoteMachman (daemon).
//

import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MachmanUI
import MachmanAPI

// One user-facing failure: title = what the user was doing, message = why it failed.
struct PresentedError: Identifiable {
	let id = UUID()
	let title: String
	let message: String
}

// A start refused with macConflict, held so the alert can retry it with force.
struct PendingForceStart: Identifiable {
	let id = UUID()
	let name: String
	let headless: Bool
	let safe: Bool
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
	// The serial terminal on screen (set by the port detail view) so the File menu and the
	// port's toolbar can save its transcript.
	@Published var activeSerialTerminal: SerialTerminalController?
	@Published var presentedError: PresentedError?
	// Binding surface for .alert(isPresented:presenting:) — clears the item on dismiss.
	var isErrorPresented: Bool {
		get { presentedError != nil }
		set { if !newValue { presentedError = nil } }
	}
	@Published var pendingForceStart: PendingForceStart?
	var isForceStartPresented: Bool {
		get { pendingForceStart != nil }
		set { if !newValue { pendingForceStart = nil } }
	}
	@Published var copyRequest: VMInfo?          // non-nil presents CopyVMSheet
	@Published private(set) var copyInFlight = false
	@Published var safeSaveRequest: VMInfo?      // non-nil presents SafeSaveSheet
	@Published private(set) var safeSaveInFlight = false
	// Live file transfers outside the duplicate sheet (imports, promotes, safe-run shadow
	// builds), keyed by VM name — non-empty presents TransferProgressView.
	struct TransferProgress: Equatable {
		var done: UInt64
		var total: UInt64
	}
	@Published private(set) var transfers: [String: TransferProgress] = [:]
	@Published private(set) var copyProgress: (done: UInt64, total: UInt64)?

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
		case .copyProgress(let vm, let copied, let total):
			if copyInFlight {
				// The duplicate sheet owns its own bar.
				copyProgress = (done: copied, total: total)
			} else if copied >= total {
				transfers[vm] = nil
			} else {
				// Disk imports/promotes and safe-run shadow builds land here — the
				// transfer popup shows them.
				transfers[vm] = TransferProgress(done: copied, total: total)
			}
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
		// A failed transfer never emits its final progress event — drop any live bars so
		// the popup can't linger behind the alert.
		transfers.removeAll()
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
			// The plain affordance honors the VM's start policy; explicit menu items force
			// only their WINDOW mode (safe applies everywhere — silently dropping safety
			// would be the one surprise worse than none). nil policy = old daemon defaults.
			let policy = vm.startPolicy ?? StartPolicy()
			startVM(vm.name, headless: !policy.windowed, safe: policy.safe)
		}
	}

	func startVM(_ name: String, headless: Bool = false, force: Bool = false, safe: Bool = false) {
		Task { [weak self] in
			do {
				try await self?.api.start(
					vm: name,
					options: StartOptions(openWindow: !headless, force: force, safe: safe))
			} catch let error as MachmanError where error.code == .macConflict {
				// Not a dead end: the same start succeeds with force, so offer it.
				self?.pendingForceStart = PendingForceStart(
					name: name, headless: headless, safe: safe, message: error.message)
			} catch {
				self?.present(error, while: "Starting \(name)")
			}
		}
	}

	func openWindow(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.openWindow(vm: name)
			} catch {
				self?.present(error, while: "Opening the \(name) window")
			}
		}
	}

	func closeWindow(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.closeWindow(vm: name)
			} catch {
				self?.present(error, while: "Closing the \(name) window")
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

	func requestCopy(_ vm: VMInfo) {
		// The sheet's space hint reads capabilities.freeDiskBytes, fetched once at connect —
		// refresh so the figure isn't sessions old.
		Task { [weak self] in
			if let caps = try? await self?.api.hostCapabilities() {
				self?.capabilities = caps
			}
		}
		copyRequest = vm
	}

	func copyVM(_ name: String, newName: String, diskIDs: [String]) {
		guard !copyInFlight else { return }
		copyInFlight = true
		copyProgress = nil
		Task { [weak self] in
			do {
				let copy = try await self?.api.copyVM(
					vm: name, newName: newName, diskIDs: diskIDs, regenerateMAC: true)
				self?.copyInFlight = false
				self?.copyProgress = nil
				self?.copyRequest = nil        // item binding dismisses the sheet
				await self?.reload()
				if let copy { self?.select(name: copy.name) }
			} catch {
				self?.copyInFlight = false
				self?.copyProgress = nil
				self?.copyRequest = nil        // dismiss first so the alert isn't sheet-blocked
				self?.present(error, while: "Duplicating \(name)")
			}
		}
	}

	func defaultCopyName(for name: String) -> String {
		let base = "\(name) copy"
		guard hasVM(base) else { return base }
		var n = 2
		while hasVM("\(base) \(n)") { n += 1 }
		return "\(base) \(n)"
	}

	func importDisk(_ name: String, path: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.importDisk(vm: name, path: path)
			} catch {
				self?.present(error, while: "Importing a disk into \(name)")
			}
		}
	}

	func promoteDisk(_ name: String, diskID: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.promoteDisk(vm: name, diskID: diskID)
			} catch {
				self?.present(error, while: "Promoting a disk on \(name)")
			}
		}
	}

	func setDiskSafety(_ name: String, diskID: String, safe: Bool) {
		Task { [weak self] in
			do {
				try await self?.api.setSafety(vm: name, disks: [diskID: safe], mounts: nil)
			} catch {
				self?.present(error, while: "Updating disk safety")
			}
		}
	}

	func setMountSafety(_ name: String, mountID: String, safe: Bool) {
		Task { [weak self] in
			do {
				try await self?.api.setSafety(vm: name, disks: nil, mounts: [mountID: safe])
			} catch {
				self?.present(error, while: "Updating mount safety")
			}
		}
	}

	func requestSafeSave(_ vm: VMInfo) {
		safeSaveRequest = vm
	}

	func defaultSafeSaveName(for name: String) -> String {
		let base = "\(name) saved"
		guard hasVM(base) else { return base }
		var n = 2
		while hasVM("\(base) \(n)") { n += 1 }
		return "\(base) \(n)"
	}

	func safeSave(_ name: String, to newName: String) {
		guard !safeSaveInFlight else { return }
		safeSaveInFlight = true
		Task { [weak self] in
			do {
				let saved = try await self?.api.safeSave(vm: name, to: newName)
				self?.safeSaveInFlight = false
				self?.safeSaveRequest = nil        // item binding dismisses the sheet
				await self?.reload()
				if let saved { self?.select(name: saved.name) }
			} catch {
				self?.safeSaveInFlight = false
				self?.safeSaveRequest = nil        // dismiss first; alert isn't sheet-blocked
				self?.present(error, while: "Saving \(name) as a new VM")
			}
		}
	}

	func setStartPolicy(_ name: String, policy: StartPolicy) {
		Task { [weak self] in
			do {
				try await self?.api.setStartPolicy(vm: name, policy: policy)
			} catch {
				self?.present(error, while: "Updating run defaults for \(name)")
			}
		}
	}

	func regenerateMAC(_ name: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.regenerateMAC(vm: name)
			} catch {
				self?.present(error, while: "Regenerating the MAC address")
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

	func addConsolePort(_ name: String) {
		Task { [weak self] in
			do { try await self?.api.addConsolePort(vm: name) }
			catch { self?.present(error, while: "Adding a console port") }
		}
	}

	func removeConsolePort(_ name: String) {
		Task { [weak self] in
			do { try await self?.api.removeConsolePort(vm: name) }
			catch { self?.present(error, while: "Removing a console port") }
		}
	}

	func addUartPort(_ name: String) {
		Task { [weak self] in
			do { try await self?.api.addUartPort(vm: name) }
			catch { self?.present(error, while: "Adding a UART port") }
		}
	}

	func removeUartPort(_ name: String) {
		Task { [weak self] in
			do { try await self?.api.removeUartPort(vm: name) }
			catch { self?.present(error, while: "Removing a UART port") }
		}
	}

	// Save the on-screen console transcript. Shared by the port toolbar and File → Save Console.
	func saveActiveConsoleTranscript() {
		guard let terminal = activeSerialTerminal else { return }
		let panel = NSSavePanel()
		panel.nameFieldStringValue = "console.log"
		panel.allowedContentTypes = [.plainText]
		if panel.runModal() == .OK, let url = panel.url {
			do {
				try terminal.transcript().write(to: url)
			} catch {
				present(error, while: "Saving the console log")
			}
		}
	}

	func setSerialLogging(
		_ name: String, kind: SerialPortKind, index: Int, config: SerialLogConfig
	) {
		Task { [weak self] in
			do {
				try await self?.api.setSerialLogging(
					vm: name, kind: kind, index: index, config: config)
			} catch {
				self?.present(error, while: "Updating serial logging")
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
