//
//  VMListViewModel.swift
//  MachmanDesktopCore
//
//  The client half of the app: view-facing state fed exclusively through MachmanControlling
//  and its event stream. Holds no engine objects — only DTOs, selection, preview images, and
//  install-phase snapshots. The app hands it the daemon connection (RemoteMachman); tests
//  and the render tool hand it StubMachman. This file keeps the state and its wiring, the
//  alerts and the selection; the jobs live in extensions by responsibility: +Actions (what
//  the user asks of the daemon), +Toasts, +ListAnnouncer, and the forms', tree's and tabs'
//  files.
//

import Foundation
import SwiftUI
import Combine
import MachmanUI
import MachmanAPI

// One user-facing failure: title = what the user was doing, message = why it failed.
public struct PresentedError: Identifiable {
	public let id = UUID()
	public let title: String
	public let message: String
}

// A Force Stop that can't reach a VM whose vmhost doesn't answer, held so the alert can end
// its process instead — only after this second, explicit question (C9).
public struct PendingEndProcess: Identifiable {
	public let id = UUID()
	public let vm: String
	public var prompt: EndProcessPrompt { .forVM(vm) }
}

// A start refused with macConflict, held so the alert can retry it with force.
public struct PendingForceStart: Identifiable {
	public let id = UUID()
	public let name: String
	public let headless: Bool
	public let safe: Bool
	public let message: String
}

@MainActor
public final class VMListViewModel: ObservableObject {
	public let api: MachmanControlling
	// The app-scoped source of truth for the list + capabilities (it survives reconnects);
	// this per-connection view model is a facade over it so views keep a single observable.
	public let store: VMStore
	// App-scoped mirror of long-running work (operations + macOS install phases).
	public let operationsStore: OperationsStore
	public var vms: [VMInfo] { store.vms }
	public var capabilities: HostCapabilities? { store.capabilities }
	public var installPhases: [String: InstallPhase] { operationsStore.installPhases }
	// App-scoped preview polling; its PreviewStore isolates the ~4s frame churn so only the
	// small PreviewView re-renders. This view model just tells it what is visible/focused.
	public let previews: PreviewService
	public var previewImages: PreviewStore { previews.images }
	@Published public var selectedName: String? = nil
	// The sidebar tree's selection (window UI state); drives the inspector's target.
	@Published public var treeSelection: Set<SidebarNode> = []
	// Live terminal controllers (app-scoped, injected): transcripts persist across VM
	// navigation AND daemon reconnects; a controller lives as long as its tab is open.
	public let terminals: TerminalSessions
	// Per-VM canvas layouts (app-scoped, injected): which tabs are open in which panes.
	public let canvases: CanvasStateStore
	// Which torn-off tabs have windows, and the orders the list reconcile posts to them.
	public let tornTabs: TornTabRegistry
	// Window-level: whether the right-hand terminal info pop-out is open. Set by the container's
	// toggle and by the sidebar's "Properties" action.
	@Published public var showInfoPanel = false
	// Failures queue: the alert shows one at a time, in arrival order (P15).
	@Published private var errorQueue = PresentationQueue<PresentedError>()
	public var presentedError: PresentedError? { errorQueue.current }
	// Binding surface for .alert(isPresented:presenting:) — a dismissal retires the shown
	// error and presents the next waiting one.
	public var isErrorPresented: Bool {
		get { presentedError != nil }
		set {
			if !newValue, errorQueue.dismiss() { presentNext { $0.errorQueue.advance() } }
		}
	}
	@Published public var pendingForceStart: PendingForceStart?
	public var isForceStartPresented: Bool {
		get { pendingForceStart != nil }
		set { if !newValue { pendingForceStart = nil } }
	}
	@Published public var pendingEndProcess: PendingEndProcess?
	public var isEndProcessPresented: Bool {
		get { pendingEndProcess != nil }
		set { if !newValue { pendingEndProcess = nil } }
	}
	// Pending destructive/choice confirmations, presented as confirmationDialogs by
	// VMNavigationView (the HIG successor to the old modal NSAlerts).
	// One copy-or-reference question for every disk file of one drop, paste or pick.
	public struct PendingDiskAdd: Identifiable {
		public let id = UUID()
		public let vm: String
		public let urls: [URL]   // never empty

		public var title: String {
			urls.count == 1
				? "Add \u{201C}\(urls[0].lastPathComponent)\u{201D}?"
				: "Copy or reference these \(urls.count) files?"
		}

		public var message: String {
			urls.count == 1
				? "Copy \(urls[0].lastPathComponent) into \(vm) (an independent copy that "
					+ "travels with the VM), or reference the original in place?"
				: "Copies travel with \(vm), and references use the originals in place."
		}
	}
	public struct PendingDiskDelete: Identifiable {
		public let id = UUID()
		public let vm: String
		public let disk: DiskInfo
	}
	public struct PendingKernelDelete: Identifiable {
		public let id = UUID()
		public let vm: String
		public let path: String
		public let fileName: String
	}
	@Published public var pendingVMDelete: VMInfo?
	// Disk-add questions queue: a second drop asked while one shows waits for its own (P17).
	@Published private var diskAddQueue = PresentationQueue<PendingDiskAdd>()
	public var pendingDiskAdd: PendingDiskAdd? { diskAddQueue.current }
	public var isDiskAddPresented: Bool {
		get { pendingDiskAdd != nil }
		set {
			if !newValue, diskAddQueue.dismiss() { presentNext { $0.diskAddQueue.advance() } }
		}
	}
	@Published public var pendingDiskDelete: PendingDiskDelete?
	@Published public var pendingKernelDelete: PendingKernelDelete?
	@Published public var copyRequest: VMInfo?          // non-nil presents CopyVMSheet
	@Published public internal(set) var copyInFlight = false
	// vm.state flips to .starting only when the vmhost's first event lands — 0.5–2 s after
	// the click — so every start affordance would happily double-fire into the daemon in
	// that window. Set synchronously on click, cleared when the request settled and a
	// fresh list was fetched (copyInFlight's shape, per-VM).
	@Published public internal(set) var pendingStarts: Set<String> = []
	@Published public var safeSaveRequest: VMInfo?      // non-nil presents SafeSaveSheet
	// File ▸ New VM… asks the main window's toolbar picker to open on its template page;
	// the picker clears it as it opens (VMIndicatorCluster).
	@Published public var newVMChooserRequested = false
	// The Stop menu's Shut Down… (⌘.) and Force Stop… (⌥⌘.) ask first (P26); non-nil
	// presents the question on the main window.
	@Published public var pendingStop: PendingStop?
	@Published public internal(set) var safeSaveInFlight = false

	// MARK: Toasts (VMListViewModel+Toasts.swift)

	// Bottom-right transient toasts (engine warnings/errors, confirmations). Lifetime is
	// the user's setting; transfers show as progress cards from OperationsStore instead.
	@Published public internal(set) var toasts: [MachmanToast] = []
	// Toasts the pointer rests on stay until it leaves, then live a fresh lifetime (F6), so a
	// long warning can be read; each timed toast's expiry is tracked to restart it.
	var heldToasts: Set<UUID> = []
	var toastExpiries: [UUID: Task<Void, Never>] = [:]
	// Tests shorten a toast's life without touching the user's setting.
	var toastLifetimeOverride: Duration?

	// MARK: List announcer (VMListViewModel+ListAnnouncer.swift)

	// Last state seen per VM, for outcome toasts: diffing the store's list catches changes
	// that arrive via reload (no discrete event) and dedupes doubled events.
	var knownStates: [String: VMState] = [:]
	var knownSSH: [String: SSHSnapshot] = [:]
	// Re-run Address Discovery / Check Connection (F4): the VMs waiting on an answer (each
	// with its timeout) and those that heard one, so even "nothing changed" is said.
	var rediscovering: [String: Task<Void, Never>] = [:]
	var rediscoveryAnswered: Set<String> = []
	// How long a re-run waits before saying the daemon keeps looking (tests shorten it).
	var rediscoveryWait: Duration = .seconds(30)

	private var eventTask: Task<Void, Never>?
	private var storeForwarder: AnyCancellable?
	private var operationsForwarder: AnyCancellable?
	private var canvasForwarder: AnyCancellable?
	private var activeTabReactor: AnyCancellable?
	private var listReactor: AnyCancellable?

	public var selected: VMInfo? {
		selectedName.flatMap { name in vms.first { $0.name == name } }
	}

	// `tornTabs` defaults to the app's shared registry; tests pass their own.
	public init(
		api: MachmanControlling, store: VMStore, operations: OperationsStore,
		terminals: TerminalSessions, previews: PreviewService, canvases: CanvasStateStore,
		tornTabs: TornTabRegistry? = nil
	) {
		self.api = api
		self.store = store
		self.operationsStore = operations
		self.terminals = terminals
		self.previews = previews
		self.canvases = canvases
		self.tornTabs = tornTabs ?? .shared
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
		// Canvas → tree (T8): a switch of the shown VM's active tab selects that tab's row.
		// $canvases emits the incoming layouts on willSet, so the store still holds the old
		// ones to compare against; dropFirst skips the replay of the stored layouts at init.
		activeTabReactor = canvases.$canvases.dropFirst().sink { [weak self] incoming in
			self?.canvasesWillChange(incoming)
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

	public func reload() async {
		await store.reload()
	}

	private func listRefreshed(_ list: [VMInfo]) {
		// Terminals + canvas layouts follow the list: drop controllers of gone VMs, forget
		// their layouts, and close tabs whose port vanished (tearing down the controller and
		// deselecting the port's row, as every close does).
		terminals.reconcile(vms: list)
		let names = Set(list.map(\.name))
		for vmName in Array(canvases.canvases.keys) where !names.contains(vmName) {
			canvases.removeVM(vmName)
		}
		for vm in list {
			let ports = (vm.consolePorts ?? []) + (vm.uartPorts ?? [])
			let refs = Set(ports.map { SerialPortRef($0) })
			for ref in canvases.reconcile(vm: vm.name, existing: refs) {
				terminals.drop(.terminal(ref), vm: vm.name)
				tabClosed(.terminal(ref), vm: vm.name)
			}
		}
		pruneTreeSelection(incoming: list)   // T15: rows whose entity went away
		// Torn tabs live in their windows, not the canvas — reconcile them too (T6): a
		// torn tab whose VM or port left the list gets a close order its own window
		// resolves (dismissWindow is a view environment action; models can only post).
		hasRefreshedList = true
		reconcileTornTabs(list: list)
		operationsStore.primeInstallPhases(for: list)
		announce(list)
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
			break   // VMStore patches the row; outcome toasts diff the list itself
		case .listChanged:
			break   // the store reloads; listRefreshed() reacts once the list lands
		case .installPhaseChanged:
			break   // OperationsStore owns phases on its own stream
		case .log(let vm, let level, let message):
			announceEngineLog(vm: vm, level: level, message: message)
		case .copyProgress:
			break   // legacy wire event; the operation cards carry all copy progress
		case .operationChanged:
			// OperationsStore owns operations (the progress cards) on its own stream.
			break
		case .sshChanged(let vm):
			// Discovery answers arrive with no listChanged — refresh the rows ourselves.
			if rediscovering[vm] != nil { rediscoveryAnswered.insert(vm) }
			Task { [weak self] in await self?.store.reload() }
		case .setupChanged:
			// Guest-setup reports land with no listChanged — same treatment.
			Task { [weak self] in await self?.store.reload() }
		case .unknown:
			break
		}
	}

	public func log(message: String) {
		MachmanLogger.log(.log, message)
	}

	// MARK: - Alerts and questions

	// Alerts always log first: the unified log keeps the record even if the alert is
	// dismissed unread.
	public func present(message: String, while action: String) {
		MachmanLogger.log(.interactionError, "\(action) failed: \(message)")
		errorQueue.enqueue(
			PresentedError(title: "\(action) failed", message: message),
			duplicate: { $0.title == $1.title && $0.message == $1.message })
	}

	// An alert whose title is the whole story, not "<action> failed".
	public func present(title: String, message: String) {
		MachmanLogger.log(.interactionError, "\(title): \(message)")
		errorQueue.enqueue(
			PresentedError(title: title, message: message),
			duplicate: { $0.title == $1.title && $0.message == $1.message })
	}

	// A dismissed alert or dialog animates out; the next one is presented after that, not
	// inside it.
	static let representDelay: Duration = .milliseconds(350)

	private func presentNext(_ step: @escaping @MainActor (VMListViewModel) -> Void) {
		Task { [weak self] in
			try? await Task.sleep(for: Self.representDelay)
			guard let self else { return }
			step(self)
		}
	}

	public func present(_ error: Error, while action: String) {
		present(message: Self.message(for: error), while: action)
	}

	// The shared rule (MachmanError.userMessage): the error's own sentence, never a struct
	// dump or an NSError's "Error Domain=… Code=…".
	static func message(for error: Error) -> String {
		MachmanError.userMessage(for: error)
	}

	// A refusal goes to the field that asked when it passed `refused` (logged as an alert
	// would be), else to an alert.
	func refuse(
		_ message: String, while action: String, to refused: (@MainActor (String) -> Void)?
	) {
		guard let refused else {
			present(message: message, while: action)
			return
		}
		MachmanLogger.log(.interactionError, "\(action) refused: \(message)")
		refused(message)
	}

	func refuse(
		_ error: Error, while action: String, to refused: (@MainActor (String) -> Void)?
	) {
		refuse(Self.message(for: error), while: action, to: refused)
	}

	public func askDiskAdd(vm: String, urls: [URL]) {
		guard !urls.isEmpty else { return }
		diskAddQueue.enqueue(PendingDiskAdd(vm: vm, urls: urls))
	}

	// MARK: - Install phases

	public func installPhase(for vm: VMInfo) -> InstallPhase {
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
		case .unknown:
			// A newer daemon's state this build can't name — claim nothing.
			return InstallPhase(kind: .idle)
		}
	}

	public func isInstalling(_ vm: VMInfo) -> Bool {
		switch installPhase(for: vm).kind {
		case .resolving, .downloading, .installing:
			return true
		case .idle, .installed, .failed, .interrupted:
			return false
		}
	}

	// MARK: - List / selection

	public func hasVM(_ name: String) -> Bool {
		vms.contains { $0.name == name }
	}

	public func select(name: String?) {
		// The tree shows ONE VM, so its selection dies with the VM it was made in.
		// Clearing here (not only in the tree's own onChange) covers switches that pass
		// through nil — delete unmounts the tree, and the remount's onAppear would
		// otherwise restore the dead VM's nodes into the next VM's tree.
		if name != selectedName {
			treeSelection = []
		}
		selectedName = name
		previews.setVisible(name.map { [$0] } ?? [])
	}

	// The terminal on the selected VM's active canvas tab (nil on the config tab or with no
	// selection) — drives File → Save Terminal.
	public var activeTerminalController: (any TerminalController)? {
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
	public var copyableSelectionItems: [EntityClipboard] {
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

	// MARK: - Torn tabs

	// Guards the torn-tab reconcile against the pre-first-list window: at launch the list
	// is empty until the first refresh, and closing restored windows against it would be
	// wrong. Per-connection state, like everything else on this view model.
	private var hasRefreshedList = false

	// A torn window calls this as it appears — restores can land between refreshes, and
	// its payload may already be stale.
	public func reconcileTornTabs() {
		guard hasRefreshedList else { return }
		reconcileTornTabs(list: store.vms)
	}

	private func reconcileTornTabs(list: [VMInfo]) {
		let registry = tornTabs
		var next: [TornTab: TornTabRegistry.Order] = [:]
		// Pending orders survive recomputes until their window acts: a rename swap must not
		// degrade to a close (the old-named payload IS stale in the fresh list), and a close
		// the user asked for (closeTab) must not be dropped by a refresh that lands first.
		for (torn, order) in registry.orders where registry.open.contains(torn) {
			next[torn] = order
		}
		for torn in registry.open where next[torn] == nil && torn.isStale(in: list) {
			next[torn] = .close
		}
		if registry.orders != next { registry.orders = next }
	}
}
