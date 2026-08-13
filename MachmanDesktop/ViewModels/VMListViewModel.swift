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
	// The sidebar tree's selection (window UI state); drives the inspector's target.
	@Published var treeSelection: Set<SidebarNode> = []
	// Live terminal controllers (app-scoped, injected): transcripts persist across VM
	// navigation AND daemon reconnects; a controller lives as long as its tab is open.
	let terminals: TerminalSessions
	// Per-VM canvas layouts (app-scoped, injected): which tabs are open in which panes.
	let canvases: CanvasStateStore
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
	@Published private(set) var copyProgress: (done: UInt64, total: UInt64)?
	// Bottom-right transient toasts (engine warnings/errors, confirmations). Lifetime is
	// the user's setting; transfers show as progress cards from OperationsStore instead.
	@Published private(set) var toasts: [MachmanToast] = []

	static let toastSecondsKey = "MachmanToastSeconds"
	static let defaultToastSeconds = 4.0

	private var eventTask: Task<Void, Never>?
	private var storeForwarder: AnyCancellable?
	private var operationsForwarder: AnyCancellable?
	private var canvasForwarder: AnyCancellable?
	private var listReactor: AnyCancellable?

	var selected: VMInfo? {
		selectedName.flatMap { name in vms.first { $0.name == name } }
	}

	init(
		api: MachmanControlling, store: VMStore, operations: OperationsStore,
		terminals: TerminalSessions, previews: PreviewService, canvases: CanvasStateStore
	) {
		self.api = api
		self.store = store
		self.operationsStore = operations
		self.terminals = terminals
		self.previews = previews
		self.canvases = canvases
		// Views observe this object, not the stores — forward their changes.
		storeForwarder = store.objectWillChange.sink { [weak self] in
			self?.objectWillChange.send()
		}
		operationsForwarder = operations.objectWillChange.sink { [weak self] in
			self?.objectWillChange.send()
		}
		// Canvas changes flip menu state (Save Terminal follows the active tab).
		canvasForwarder = canvases.objectWillChange.sink { [weak self] in
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
		// Terminals + canvas layouts follow the list: drop controllers of gone VMs, forget
		// their layouts, and close tabs whose port vanished (tearing down the controller).
		terminals.reconcile(vms: list)
		let names = Set(list.map(\.name))
		for vmName in Array(canvases.canvases.keys) where !names.contains(vmName) {
			canvases.removeVM(vmName)
		}
		for vm in list {
			let ports = (vm.consolePorts ?? []) + (vm.uartPorts ?? [])
			let refs = Set(ports.map { SerialPortRef($0) })
			for ref in canvases.reconcile(vm: vm.name, existing: refs) {
				terminals.dropController(vm: vm.name, ref: ref)
			}
		}
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
		case .stateChanged(let name, let state):
			// VMStore patches the row and PreviewService restarts its loop; here the
			// outcome pops as a toast (transitions stay quiet).
			switch state {
			case .running:
				pushToast(symbol: MachmanSymbols.start, message: "\(name) started")
			case .stopped:
				pushToast(symbol: MachmanSymbols.shutDown, message: "\(name) stopped")
			case .error:
				pushToast(
					symbol: MachmanSymbols.warning, message: "\(name) hit an error",
					tint: MachmanColors.warning)
			default:
				break
			}
		case .listChanged:
			break   // the store reloads; listRefreshed() reacts once the list lands
		case .installPhaseChanged:
			break   // OperationsStore owns phases on its own stream
		case .log(let vm, let level, let message):
			// The engine logs these in its own process too, but that process is auto-launched —
			// relaying through the client's logger keeps engine warnings visible from the app
			// the user actually runs.
			MachmanLogger.log(level.logType, "\(vm.map { "(\($0)) " } ?? "")\(message)")
			if level == .warning || level == .error {
				pushToast(
					symbol: MachmanSymbols.warning,
					message: "\(vm.map { "\($0): " } ?? "")\(message)",
					tint: MachmanColors.warning)
			}
		case .copyProgress(let vm, let copied, let total):
			_ = vm
			if copyInFlight {
				// The duplicate sheet owns its own bar; every other transfer shows as a
				// progress card fed by operationChanged.
				copyProgress = (done: copied, total: total)
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
		presentedError = PresentedError(title: "\(action) failed", message: message)
	}

	// A transient bottom-right toast; lifetime comes from the user's setting.
	func pushToast(symbol: String, message: String, tint: Color? = nil) {
		let toast = MachmanToast(symbol: symbol, message: message, tint: tint)
		toasts.append(toast)
		let stored = UserDefaults.standard.double(forKey: Self.toastSecondsKey)
		let seconds = stored > 0 ? stored : Self.defaultToastSeconds
		Task { [weak self] in
			try? await Task.sleep(for: .seconds(seconds))
			self?.toasts.removeAll { $0.id == toast.id }
		}
	}

	func cancelOperation(id: String) {
		Task { [weak self] in
			do { try await self?.api.cancelOperation(id: id) }
			catch { self?.present(error, while: "Canceling the operation") }
		}
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
			canvases.renameVM(from: oldName, to: newName)
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

	func setHardware(
		_ name: String, cpuCount: Int? = nil, memoryBytes: UInt64? = nil, nested: Bool? = nil
	) {
		Task { [weak self] in
			do {
				try await self?.api.setHardware(
					vm: name, cpuCount: cpuCount, memoryBytes: memoryBytes,
					nestedVirtualization: nested)
			} catch {
				self?.present(error, while: "Updating hardware for \(name)")
			}
		}
	}

	// The one rename flow (tree rename-in-place + the VM inspector's name field):
	// dup-checked, migrating terminal/canvas/preview/profile state on success.
	func requestRename(_ vm: VMInfo, to newName: String, profiles: TerminalProfileStore) {
		let old = vm.name
		guard !newName.isEmpty, newName != old else { return }
		guard !hasVM(newName) else {
			present(
				message: "A VM named '\(newName)' already exists.",
				while: "Renaming \(old)")
			return
		}
		Task { [weak self] in
			guard let self = self else { return }
			if await self.rename(from: old, to: newName) {
				profiles.renameVM(from: old, to: newName)
				self.log(message: "Renamed \(old) to \(newName)")
				self.pushToast(
					symbol: MachmanSymbols.rename,
					message: "Renamed to \u{201C}\(newName)\u{201D}")
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

	// The disk id derives from the name, so a successful rename repoints a selection that
	// was on the old id (the inspector would otherwise go blank).
	func renameDisk(_ name: String, diskID: String, newName: String) {
		Task { [weak self] in
			do {
				guard let updated = try await self?.api.renameDisk(
					vm: name, diskID: diskID, newName: newName) else { return }
				if self?.treeSelection == [.disk(diskID)],
					let newID = updated.disks.first(where: { $0.name == newName })?.id {
					self?.treeSelection = [.disk(newID)]
				}
				self?.pushToast(
					symbol: MachmanSymbols.rename,
					message: "Disk renamed to \u{201C}\(newName)\u{201D}")
			} catch {
				self?.present(error, while: "Renaming a disk")
			}
		}
	}

	func setMountTag(_ name: String, mountID: String, tag: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.setMountTag(vm: name, mountID: mountID, tag: tag)
				self?.pushToast(
					symbol: MachmanSymbols.rename,
					message: "Mount tag changed to \u{201C}\(tag)\u{201D}")
			} catch {
				self?.present(error, while: "Changing a mount tag")
			}
		}
	}

	// The file's path changes with its tag — repoint a selection that was on the old path.
	func renameKernelTag(_ name: String, path: String, tag: String) {
		let fileName = (path as NSString).lastPathComponent
		Task { [weak self] in
			do {
				guard let updated = try await self?.api.renameKernelFile(
					vm: name, path: path, tag: tag) else { return }
				guard let file = updated.boot.ownedKernels?.first(where: {
					$0.tag == tag && $0.fileName == fileName
				}) else { return }
				let old: SidebarNode = file.role == .kernel ? .kernel(path) : .initramfs(path)
				if self?.treeSelection == [old] {
					self?.treeSelection = [file.role == .kernel
						? .kernel(file.path) : .initramfs(file.path)]
				}
				self?.pushToast(
					symbol: MachmanSymbols.rename,
					message: "Re-tagged \u{201C}\(tag)\u{201D}")
			} catch {
				self?.present(error, while: "Renaming a kernel file")
			}
		}
	}

	func resizeDisk(_ name: String, diskID: String, sizeBytes: UInt64) {
		Task { [weak self] in
			do {
				_ = try await self?.api.resizeDisk(
					vm: name, diskID: diskID, sizeBytes: sizeBytes)
			} catch {
				self?.present(error, while: "Growing a disk")
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
				self?.pushToast(
					symbol: MachmanSymbols.regenerate, message: "MAC address regenerated")
			} catch {
				self?.present(error, while: "Regenerating the MAC address")
			}
		}
	}

	// System-prompted host install; capabilities refresh afterwards so the availability
	// row flips without a reconnect.
	func installRosetta() {
		Task { [weak self] in
			do {
				try await self?.api.installRosetta()
				await self?.store.refreshCapabilities()
			} catch {
				self?.present(error, while: "Installing Rosetta")
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
				self?.pushToast(symbol: MachmanSymbols.diskStorage, message: "Added disk")
			} catch {
				self?.present(error, while: "Adding a disk")
			}
		}
	}

	func removeDisk(_ name: String, diskID: String) {
		Task { [weak self] in
			do {
				try await self?.api.removeDisk(vm: name, diskID: diskID)
				self?.pushToast(symbol: MachmanSymbols.diskStorage, message: "Removed disk")
			} catch {
				self?.present(error, while: "Removing a disk")
			}
		}
	}

	func addMount(_ name: String, path: String, tag: String) {
		Task { [weak self] in
			do {
				try await self?.api.addMount(vm: name, path: path, tag: tag)
				self?.pushToast(
					symbol: MachmanSymbols.mount, message: "Added mount \u{201C}\(tag)\u{201D}")
			} catch {
				self?.present(error, while: "Adding a mount point")
			}
		}
	}

	func removeMount(_ name: String, mountID: String) {
		Task { [weak self] in
			do {
				try await self?.api.removeMount(vm: name, mountID: mountID)
				self?.pushToast(symbol: MachmanSymbols.mount, message: "Removed mount")
			} catch {
				self?.present(error, while: "Removing a mount point")
			}
		}
	}

	func addDevice(_ name: String, kind: DeviceKind) {
		Task { [weak self] in
			do {
				_ = try await self?.api.addDevice(vm: name, kind: kind)
				self?.pushToast(
					symbol: kind.displaySymbol, message: "Added \(kind.displayLabel)")
			}
			catch { self?.present(error, while: "Adding a device") }
		}
	}

	func removeDevice(_ name: String, kind: DeviceKind) {
		Task { [weak self] in
			do {
				_ = try await self?.api.removeDevice(vm: name, kind: kind)
				self?.pushToast(
					symbol: kind.displaySymbol, message: "Removed \(kind.displayLabel)")
			}
			catch { self?.present(error, while: "Removing a device") }
		}
	}

	func updateDevice(_ name: String, device: DeviceInfo) {
		Task { [weak self] in
			do { _ = try await self?.api.updateDevice(vm: name, device: device) }
			catch { self?.present(error, while: "Updating a device") }
		}
	}

	// Batch per-entity enabled flags; serial ports are keyed by their string index.
	func setEnabled(
		_ name: String, disks: [String: Bool]? = nil, mounts: [String: Bool]? = nil,
		console: [String: Bool]? = nil, uart: [String: Bool]? = nil
	) {
		Task { [weak self] in
			do {
				try await self?.api.setEnabled(
					vm: name, disks: disks, mounts: mounts, console: console, uart: uart)
			} catch {
				self?.present(error, while: "Updating enabled state")
			}
		}
	}

	func addConsolePort(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.addConsolePort(vm: name)
				self?.pushToast(
					symbol: MachmanSymbols.serialConsole, message: "Added console port")
			}
			catch { self?.present(error, while: "Adding a console port") }
		}
	}

	func removeConsolePort(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.removeConsolePort(vm: name)
				self?.pushToast(
					symbol: MachmanSymbols.serialConsole, message: "Removed console port")
			}
			catch { self?.present(error, while: "Removing a console port") }
		}
	}

	func addUartPort(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.addUartPort(vm: name)
				self?.pushToast(symbol: MachmanSymbols.serialUart, message: "Added UART port")
			}
			catch { self?.present(error, while: "Adding a UART port") }
		}
	}

	func removeUartPort(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.removeUartPort(vm: name)
				self?.pushToast(
					symbol: MachmanSymbols.serialUart, message: "Removed UART port")
			}
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

	// The terminal on the selected VM's active canvas tab (nil on the config tab or with no
	// selection) — drives File → Save Terminal.
	var activeTerminalController: SerialTerminalController? {
		guard let name = selectedName,
			case .terminal(let ref) = canvases.canvas(for: name).activeTab else { return nil }
		return terminals.controller(vm: name, ref: ref)
	}

	// MARK: - Canvas commands (menu shortcuts)

	func cycleTab(forward: Bool) {
		guard let name = selectedName else { return }
		var canvas = canvases.canvas(for: name)
		guard let pane = canvas.activePane, pane.tabs.count > 1,
			let current = pane.active,
			let index = pane.tabs.firstIndex(of: current) else { return }
		let count = pane.tabs.count
		canvas.activate(pane.tabs[(index + (forward ? 1 : count - 1)) % count])
		canvases.setCanvas(canvas, for: name)
	}

	func closeActiveTab() {
		guard let name = selectedName else { return }
		var canvas = canvases.canvas(for: name)
		guard let tab = canvas.activeTab else { return }
		if case .terminal(let ref) = tab {
			terminals.dropController(vm: name, ref: ref)
		}
		canvas.close(tab)
		canvases.setCanvas(canvas, for: name)
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

	// Select/deselect an active kernel or initramfs file by rewiring the kernel-boot draft
	// (the settings survive as a draft even while the mode is EFI — never toggles the mode).
	func setActiveKernelFile(_ vm: VMInfo, role: KernelRole, path: String?) {
		var settings = vm.boot.kernel
			?? KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "")
		switch role {
		case .kernel: settings.kernelPath = path ?? ""
		case .initramfs: settings.initrdPath = path
		}
		updateKernelSettings(vm.name, settings)
	}

	func setKernelOverride(
		_ name: String, path: String, commandLine: String? = nil, overrideEnabled: Bool? = nil
	) {
		Task { [weak self] in
			do {
				_ = try await self?.api.setKernelOverride(
					vm: name, path: path, commandLine: commandLine,
					overrideEnabled: overrideEnabled)
			} catch {
				self?.present(error, while: "Updating the kernel override")
			}
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
