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
	// Pending destructive/choice confirmations, presented as confirmationDialogs by
	// VMNavigationView (the HIG successor to the old modal NSAlerts).
	struct PendingDiskAdd: Identifiable {
		let id = UUID()
		let vm: String
		let url: URL
	}
	struct PendingDiskDelete: Identifiable {
		let id = UUID()
		let vm: String
		let disk: DiskInfo
	}
	struct PendingKernelDelete: Identifiable {
		let id = UUID()
		let vm: String
		let path: String
		let fileName: String
	}
	@Published var pendingVMDelete: VMInfo?
	@Published var pendingDiskAdd: PendingDiskAdd?
	@Published var pendingDiskDelete: PendingDiskDelete?
	@Published var pendingKernelDelete: PendingKernelDelete?
	@Published var copyRequest: VMInfo?          // non-nil presents CopyVMSheet
	@Published private(set) var copyInFlight = false
	@Published var safeSaveRequest: VMInfo?      // non-nil presents SafeSaveSheet
	@Published private(set) var safeSaveInFlight = false
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
	// Last state seen per VM, for outcome toasts: diffing the store's list catches changes
	// that arrive via reload (no discrete event) and dedupes doubled events.
	private var knownStates: [String: VMState] = [:]

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
		diffStatesAndToast(list)
		diffSSHAndToast(list)
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

	// Outcome toasts off the list itself (every patch and reload lands here): a VM newly
	// running/stopped/errored toasts exactly once, transitions stay quiet, and a first
	// sighting (launch, reconnect, creation) never toasts.
	private func diffStatesAndToast(_ list: [VMInfo]) {
		for vm in list {
			let previous = knownStates[vm.name]
			knownStates[vm.name] = vm.state
			guard let previous, previous != vm.state else { continue }
			switch vm.state {
			case .running:
				pushToast(symbol: MachmanSymbols.start, message: "\(vm.name) started")
			case .stopped where previous == .running || previous == .stopping:
				pushToast(symbol: MachmanSymbols.shutDown, message: "\(vm.name) stopped")
			case .error:
				pushToast(
					symbol: MachmanSymbols.warning, message: "\(vm.name) hit an error",
					tint: MachmanColors.warning)
			default:
				break
			}
		}
		let names = Set(list.map(\.name))
		knownStates = knownStates.filter { names.contains($0.key) }
	}

	// What the SSH half of a VM looked like last time, so only MOVEMENT is reported.
	private struct SSHSnapshot: Equatable {
		var running = false
		var address: String?
		var reachability: SSHInfo.Reachability?
		var lastReportAt: Date?
		var reverseState: SSHInfo.ReverseState = .none
	}
	private var knownSSH: [String: SSHSnapshot] = [:]

	static func sshWaitToastKey(_ vm: String) -> String { "ssh-wait-\(vm)" }

	// The SSH story, told through toasts: the guest answering at all, then whether its
	// sshd does, then what its setup run achieved. Same rule as the state diff — a first
	// sighting (launch, reconnect) never toasts, only a change does.
	private func diffSSHAndToast(_ list: [VMInfo]) {
		for vm in list {
			let now = SSHSnapshot(
				running: vm.state.isRunning,
				address: vm.ssh?.address,
				reachability: vm.ssh?.reachability,
				lastReportAt: vm.ssh?.lastReportAt,
				reverseState: vm.ssh?.reverseState ?? .none)
			let previous = knownSSH[vm.name]
			knownSSH[vm.name] = now
			guard let previous, previous != now else { continue }

			// The guest is on the network — the first sign of life Machman gets.
			if let address = now.address, previous.address != address, now.running {
				pushToast(
					symbol: MachmanSymbols.network, message: "\(vm.name) answered — \(address)")
			}
			if previous.reachability != now.reachability {
				switch now.reachability {
				case .waiting:
					pushToast(
						symbol: MachmanSymbols.deviceSSHSetup,
						message: "SSH: connecting to \(vm.name)…",
						key: Self.sshWaitToastKey(vm.name), spinner: true, sticky: true)
				case .ready:
					pushToast(
						symbol: MachmanSymbols.confirm, message: "\(vm.name): SSH ready",
						tint: MachmanColors.connected, key: Self.sshWaitToastKey(vm.name))
				case .unreachable:
					pushToast(
						symbol: MachmanSymbols.warning,
						message: "\(vm.name): SSH not answering"
							+ (vm.ssh?.reachabilityDetail.map { " — \($0)" } ?? ""),
						tint: MachmanColors.warning, key: Self.sshWaitToastKey(vm.name))
				case .unknown, nil:
					dismissToast(key: Self.sshWaitToastKey(vm.name))
				}
			}
			// A setup run landed. Its own status is the interesting half: "partial" is
			// exactly the case the old script could not report at all.
			if let stamp = now.lastReportAt, previous.lastReportAt != stamp {
				let user = vm.ssh?.guestUser ?? "the guest"
				let os = vm.ssh?.guestOS.map { " (\($0))" } ?? ""
				if let status = vm.ssh?.lastRunStatus, status != "ok" {
					pushToast(
						symbol: MachmanSymbols.warning,
						message: "\(vm.name): SSH setup \(status)"
							+ (vm.ssh?.lastRunNote.map { " — \($0)" } ?? ""),
						tint: MachmanColors.warning)
				} else {
					pushToast(
						symbol: MachmanSymbols.deviceSSHSetup,
						message: "\(vm.name): SSH set up for \(user)\(os)")
				}
			}
			if previous.reverseState != .pending, now.reverseState == .pending {
				pushToast(
					symbol: MachmanSymbols.deviceSSHSetup,
					message: "\(vm.name) asks to log in to this Mac — approve it in the "
						+ "Network inspector",
					tint: MachmanColors.warning)
			}
		}
		// A VM that stopped or vanished has no pending SSH wait to report on.
		let names = Set(list.map(\.name))
		for name in knownSSH.keys where !names.contains(name) {
			knownSSH[name] = nil
			dismissToast(key: Self.sshWaitToastKey(name))
		}
		for vm in list where !vm.state.isRunning {
			dismissToast(key: Self.sshWaitToastKey(vm.name))
		}
	}

	private func handle(event: VMEvent) {
		switch event {
		case .stateChanged:
			break   // VMStore patches the row; outcome toasts diff the list itself
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
		case .copyProgress:
			break   // legacy wire event; the operation cards carry all copy progress
		case .operationChanged:
			// The operations UI (progress cards) lands with the desktop overhaul; until
			// then the legacy copyProgress events above cover the same transfers.
			break
		case .sshChanged:
			// Discovery answers arrive with no listChanged — refresh the rows ourselves.
			Task { [weak self] in await self?.store.reload() }
		case .setupChanged:
			// Guest-setup reports land with no listChanged — same treatment.
			Task { [weak self] in await self?.store.reload() }
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

	// A bottom-right toast; lifetime comes from the user's setting. A `key` makes it a
	// named slot: pushing the same key replaces what is showing IN PLACE, so a state that
	// moves (waiting → ready) reads as one toast changing rather than three piling up.
	// `spinner` shows an indeterminate indicator instead of the symbol, and `sticky` skips
	// the timer entirely — for waits that end with another push.
	func pushToast(
		symbol: String, message: String, tint: Color? = nil,
		key: String? = nil, spinner: Bool = false, sticky: Bool = false
	) {
		let toast = MachmanToast(
			symbol: symbol, message: message, tint: tint,
			key: key, spinner: spinner, sticky: sticky)
		if let key, let existing = toasts.firstIndex(where: { $0.key == key }) {
			toasts[existing] = toast
		} else {
			toasts.append(toast)
		}
		guard !sticky else { return }
		let stored = UserDefaults.standard.double(forKey: Self.toastSecondsKey)
		let seconds = stored > 0 ? stored : Self.defaultToastSeconds
		Task { [weak self] in
			try? await Task.sleep(for: .seconds(seconds))
			self?.toasts.removeAll { $0.id == toast.id }
		}
	}

	// Retire a named slot without replacing it (the wait ended in nothing worth saying).
	func dismissToast(key: String) {
		toasts.removeAll { $0.key == key }
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

	// Request → confirmationDialog → perform (all deletes follow this shape).
	func deleteVM(_ vm: VMInfo) {
		pendingVMDelete = vm
	}

	func performDeleteVM(_ vm: VMInfo) {
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

	// Owned disks confirm (the backing file dies with the entry); references detach silently.
	func requestRemoveDisk(_ name: String, disk: DiskInfo) {
		if disk.owned == true {
			pendingDiskDelete = PendingDiskDelete(vm: name, disk: disk)
		} else {
			removeDisk(name, diskID: disk.id)
		}
	}

	func requestDeleteKernel(_ name: String, path: String, fileName: String) {
		pendingKernelDelete = PendingKernelDelete(vm: name, path: path, fileName: fileName)
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
		copyRequest = nil   // the sheet closes now; the corner card tracks the copy
		Task { [weak self] in
			do {
				let copy = try await self?.api.copyVM(
					vm: name, newName: newName, diskIDs: diskIDs, regenerateMAC: true)
				self?.copyInFlight = false
				await self?.reload()
				if let copy { self?.select(name: copy.name) }
			} catch {
				self?.copyInFlight = false
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

	func addMount(_ name: String, path: String, tag: String, kind: String? = nil) {
		Task { [weak self] in
			do {
				try await self?.api.addMount(vm: name, path: path, tag: tag, kind: kind)
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

	// MARK: - SSH (1.0.5)

	func setSSHIntegration(_ name: String, enabled: Bool) {
		Task { [weak self] in
			do {
				_ = try await self?.api.setSSH(
					vm: name, integrationEnabled: enabled, reverseApproved: nil, alias: nil)
			}
			catch { self?.present(error, while: "Updating the SSH alias") }
		}
	}

	// An empty alias resets the VM to its default "<vm>.machman" name.
	func setSSHAlias(_ name: String, alias: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.setSSH(
					vm: name, integrationEnabled: nil, reverseApproved: nil, alias: alias)
			}
			catch { self?.present(error, while: "Renaming the SSH alias") }
		}
	}

	func setSSHReverseApproved(_ name: String, approved: Bool) {
		Task { [weak self] in
			do {
				_ = try await self?.api.setSSH(
					vm: name, integrationEnabled: nil, reverseApproved: approved, alias: nil)
				self?.pushToast(
					symbol: MachmanSymbols.deviceSSHSetup,
					message: approved
						? "\(name) can now log in to this Mac"
						: "Revoked \(name)'s access to this Mac")
			}
			catch { self?.present(error, while: "Updating guest access") }
		}
	}

	func refreshSSH(_ name: String) {
		Task { [weak self] in
			do { try await self?.api.refreshSSH(vm: name) }
			catch { self?.present(error, while: "Refreshing the SSH address") }
		}
	}

	func resetSSH(_ name: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.resetSSH(vm: name)
				self?.pushToast(
					symbol: MachmanSymbols.deviceSSHSetup,
					message: "SSH state reset for \(name)")
			}
			catch { self?.present(error, while: "Resetting SSH state") }
		}
	}

	func resetSetup(_ name: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.resetSetup(vm: name)
				self?.pushToast(
					symbol: MachmanSymbols.deviceGuestSetup,
					message: "Guest-setup state reset for \(name)")
			}
			catch { self?.present(error, while: "Resetting guest-setup state") }
		}
	}

	// Batch enable/disable everything in the tree selection that carries the flag
	// (multi-select context menus + the multi-selection inspector).
	func setSelectionEnabled(_ enabled: Bool, vm: VMInfo) {
		var disks: [String: Bool] = [:]
		var mounts: [String: Bool] = [:]
		var console: [String: Bool] = [:]
		var uart: [String: Bool] = [:]
		for node in treeSelection {
			switch node {
			case .disk(let id):
				disks[id] = enabled
			case .mount(let id):
				mounts[id] = enabled
			case .serial(let ref):
				if ref.kind == .console {
					console[String(ref.index)] = enabled
				} else {
					uart[String(ref.index)] = enabled
				}
			case .device(let kind):
				if var device = vm.devices?.first(where: { $0.kind == kind }) {
					device.enabled = enabled
					updateDevice(vm.name, device: device)
				}
			default:
				break
			}
		}
		if !disks.isEmpty || !mounts.isEmpty || !console.isEmpty || !uart.isEmpty {
			setEnabled(
				vm.name, disks: disks.isEmpty ? nil : disks,
				mounts: mounts.isEmpty ? nil : mounts,
				console: console.isEmpty ? nil : console,
				uart: uart.isEmpty ? nil : uart)
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
		guard let name = selectedName else { return nil }
		switch canvases.canvas(for: name).activeTab {
		case .terminal(let ref):
			return terminals.controller(vm: name, ref: ref)
		case .ssh(let ref):
			return terminals.sshController(vm: name, ref: ref)
		default:
			return nil
		}
	}

	// Every copyable entity in the tree selection (kernel + initramfs + disks together) —
	// drives Edit → Copy Item and the multi-selection Copy.
	var copyableSelectionItems: [EntityClipboard] {
		guard let vm = selected else { return [] }
		return treeSelection.compactMap { node in
			switch node {
			case .disk(let id):
				guard let path = vm.disks.first(where: { $0.id == id })?.path else {
					return nil
				}
				return EntityClipboard(kind: .disk, path: path)
			case .mount(let id):
				guard let mount = vm.mounts.first(where: { $0.id == id }) else { return nil }
				return EntityClipboard(kind: .mount, path: mount.path, tag: mount.tag)
			case .kernel(let path):
				return EntityClipboard(kind: .kernel, path: path)
			case .initramfs(let path):
				return EntityClipboard(kind: .initramfs, path: path)
			default:
				return nil
			}
		}.sorted { $0.path < $1.path }   // Set order is unstable; keep copies deterministic
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

	// True when a tab was closed (⌘W falls back to closing the window otherwise).
	@discardableResult
	func closeActiveTab() -> Bool {
		guard let name = selectedName else { return false }
		var canvas = canvases.canvas(for: name)
		guard let tab = canvas.activeTab else { return false }
		if case .terminal(let ref) = tab {
			terminals.dropController(vm: name, ref: ref)
		}
		if case .ssh(let ref) = tab {
			terminals.dropSSHController(vm: name, ref: ref)
		}
		canvas.close(tab)
		canvases.setCanvas(canvas, for: name)
		return true
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

}
