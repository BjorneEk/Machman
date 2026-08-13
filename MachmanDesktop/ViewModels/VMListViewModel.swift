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
import Combine
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

@MainActor
final class VMListViewModel: ObservableObject {
	let api: MachmanControlling
	// The app-scoped source of truth for the list + capabilities (it survives reconnects);
	// this per-connection view model is a facade over it so views keep a single observable.
	let store: VMStore
	// App-scoped mirror of long-running work (operations + macOS install phases).
	let operationsStore: OperationsStore
	var vms: [VMInfo] { store.vms }
	var capabilities: HostCapabilities? { store.capabilities }
	var installPhases: [String: InstallPhase] { operationsStore.installPhases }
	// App-scoped preview polling; its PreviewStore isolates the ~4s frame churn so only the
	// small PreviewView re-renders. This view model just tells it what is visible/focused.
	let previews: PreviewService
	var previewImages: PreviewStore { previews.images }
	@Published var selectedName: String? = nil
	@Published var vmName: String = ""
	// Per-VM terminal tabs + their live connections. App-scoped (injected): terminals and
	// their transcripts persist across VM navigation AND daemon reconnects; a tab's
	// connection lives exactly as long as the tab is open. Observed directly by the tab views.
	let terminals: TerminalSessions
	// Window-level: whether the right-hand terminal info pop-out is open. Set by the container's
	// toggle and by the sidebar's "Properties" action.
	@Published var showInfoPanel = false
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

	private var eventTask: Task<Void, Never>?
	private var storeForwarder: AnyCancellable?
	private var operationsForwarder: AnyCancellable?
	private var listReactor: AnyCancellable?

	var selected: VMInfo? {
		selectedName.flatMap { name in vms.first { $0.name == name } }
	}

	init(
		api: MachmanControlling, store: VMStore, operations: OperationsStore,
		terminals: TerminalSessions, previews: PreviewService
	) {
		self.api = api
		self.store = store
		self.operationsStore = operations
		self.terminals = terminals
		self.previews = previews
		// Views observe this object, not the stores — forward their changes.
		storeForwarder = store.objectWillChange.sink { [weak self] in
			self?.objectWillChange.send()
		}
		operationsForwarder = operations.objectWillChange.sink { [weak self] in
			self?.objectWillChange.send()
		}
		// React AFTER every list refresh (reconcile tabs, prime phases). $vms emits the
		// incoming value on willSet — use it, never store.vms (still the old list here).
		// dropFirst skips the replay of the retained list at init: on reconnect the window's
		// onAppear restore must run before listRefreshed's selection fallback can fire.
		listReactor = store.$vms.dropFirst().sink { [weak self] list in
			self?.listRefreshed(list)
		}
		// The view model keeps its own event stream for UI-side reactions (the transport
		// fans events out per subscriber; the store patches the list on its own stream).
		eventTask = Task { [weak self] in
			guard let api = self?.api else { return }
			let stream = await api.events()
			for await event in stream {
				guard let self = self else { return }
				self.handle(event: event)
			}
		}
	}

	deinit {
		eventTask?.cancel()
	}

	func reload() async {
		await store.reload()
	}

	private func listRefreshed(_ list: [VMInfo]) {
		// Close terminal tabs for ports/VMs that no longer exist.
		terminals.reconcile(vms: list)
		operationsStore.primeInstallPhases(for: list)
		// The sidebar shows the selected VM's device tree, so something should always be
		// selected while VMs exist (launch, post-delete) — and a selection whose VM is gone
		// falls over to the first. (Renames pass through here with the old name still
		// selected; the transient first-VM pick is corrected a beat later by rename().)
		if let name = selectedName {
			if !list.contains(where: { $0.name == name }) {
				select(name: list.first?.name)
			}
		} else if let first = list.first {
			select(name: first.name)
		}
	}

	private func handle(event: VMEvent) {
		switch event {
		case .stateChanged:
			break   // VMStore patches the row; PreviewService restarts its loop
		case .listChanged:
			break   // the store reloads; listRefreshed() reacts once the list lands
		case .installPhaseChanged:
			break   // OperationsStore owns phases on its own stream
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
		case .operationChanged:
			// The operations UI (progress cards) lands with the desktop overhaul; until
			// then the legacy copyProgress events above cover the same transfers.
			break
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
		selectedName.flatMap { previewImages.images[$0] }
	}

	func isLoading() -> Bool {
		guard let vm = selected else { return false }
		return vm.state.isRunning && preview() == nil
	}

	func onFocusEvent(focused: Bool) {
		previews.setFocused(focused)
	}

	// MARK: - List / selection

	func hasVM(_ name: String) -> Bool {
		vms.contains { $0.name == name }
	}

	func select(name: String?) {
		selectedName = name
		vmName = name ?? ""
		previews.setVisible(name.map { [$0] } ?? [])
	}

	// MARK: - Actions

	func toggleRun(_ vm: VMInfo) {
		if vm.state.isRunning {
			stopVM(vm.name)
		} else {
			startPolicyDriven(vm)
		}
	}

	// The plain Start affordance honors the VM's start policy; explicit menu items force
	// only their WINDOW mode (safe applies everywhere — silently dropping safety would be
	// the one surprise worse than none). nil policy = old daemon defaults. safeOverride
	// forces safety on top of the policy's window mode (the toolbar's Start Safe).
	func startPolicyDriven(_ vm: VMInfo, safeOverride: Bool? = nil) {
		let policy = vm.startPolicy ?? StartPolicy()
		startVM(vm.name, headless: !policy.windowed, safe: safeOverride ?? policy.safe)
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

	func createVM(template: String? = nil) async -> String? {
		do {
			let vm = try await api.createVM(template: template)
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
				// The picker can delete a VM that isn't the shown one — keep the selection
				// unless it was the one deleted.
				if self?.selectedName == vm.name {
					self?.select(name: nil)
				}
			} catch {
				self?.present(error, while: "Deleting \(vm.name)")
			}
		}
	}

	func rename(from oldName: String, to newName: String) async -> Bool {
		do {
			try await api.renameVM(named: oldName, to: newName)
			// Migrate open terminal tabs BEFORE reload()'s reconcile sees the new name (else the
			// old-keyed session would look like a vanished VM and its terminals get closed).
			terminals.renameVM(from: oldName, to: newName)
			previews.renameVM(from: oldName, to: newName)
			await reload()
			select(name: newName)
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
					vm: name, cpuCount: cpuCount, memoryBytes: memoryBytes,
					nestedVirtualization: nil)
			} catch {
				self?.present(error, while: "Updating hardware for \(name)")
			}
		}
	}

	func requestCopy(_ vm: VMInfo) {
		// The sheet's space hint reads capabilities.freeDiskBytes, fetched once at connect —
		// refresh so the figure isn't sessions old.
		Task { [weak self] in
			await self?.store.refreshCapabilities()
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

	func addDevice(_ name: String, kind: DeviceKind) {
		Task { [weak self] in
			do { _ = try await self?.api.addDevice(vm: name, kind: kind) }
			catch { self?.present(error, while: "Adding a device") }
		}
	}

	func removeDevice(_ name: String, kind: DeviceKind) {
		Task { [weak self] in
			do { _ = try await self?.api.removeDevice(vm: name, kind: kind) }
			catch { self?.present(error, while: "Removing a device") }
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

	func promoteKernel(_ name: String, role: KernelRole, sourcePath: String, tag: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.promoteKernelFile(
					vm: name, role: role, sourcePath: sourcePath, tag: tag)
			} catch {
				self?.present(error, while: "Promoting a kernel file")
			}
		}
	}

	func deleteKernel(_ name: String, path: String) {
		Task { [weak self] in
			do { _ = try await self?.api.deleteKernelFile(vm: name, path: path) }
			catch { self?.present(error, while: "Deleting a kernel file") }
		}
	}

	// The terminal on the active tab of the currently-selected VM (nil on the config tab or with
	// no selection) — drives File → Save Terminal.
	var activeTerminalController: SerialTerminalController? {
		selectedName.flatMap { terminals.activeController(vm: $0) }
	}

	// Save the on-screen terminal transcript. Used by File → Save Terminal.
	func saveActiveTerminalTranscript() {
		guard let terminal = activeTerminalController else { return }
		let panel = NSSavePanel()
		panel.nameFieldStringValue = "terminal.log"
		panel.allowedContentTypes = [.plainText]
		if panel.runModal() == .OK, let url = panel.url {
			do {
				try terminal.transcript().write(to: url)
			} catch {
				present(error, while: "Saving the terminal log")
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
