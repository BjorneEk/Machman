//
//  VMListViewModel.swift
//  MachmanDesktopCore
//
//  The client half of the app: view-facing state fed exclusively through MachmanControlling
//  and its event stream. Holds no engine objects — only DTOs, selection, preview images, and
//  install-phase snapshots. The app hands it the daemon connection (RemoteMachman); tests
//  and the render tool hand it StubMachman. This file keeps the state and its wiring, the
//  alerts and the selection; the jobs live in extensions by responsibility: +Actions (what
//  the user asks of the daemon), +Toasts (over its ToastCenter), +ListAnnouncer, and the
//  forms', tree's and tabs' files.
//

import Foundation
import SwiftUI
import Combine
import MachmanUI
import MachmanAPI

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
	// The sidebar tree's selection (window state, kept across reconnects by MainWindowState);
	// drives the inspector's target.
	@Published public var treeSelection: Set<SidebarNode> = []
	// Live terminal controllers (app-scoped, injected): transcripts persist across VM
	// navigation AND daemon reconnects; a controller lives as long as its tab is open.
	public let terminals: TerminalSessions
	// Per-VM canvas layouts (app-scoped, injected): which tabs are open in which panes.
	public let canvases: CanvasStateStore
	// Which torn-off tabs have windows, and the orders the list reconcile posts to them.
	public let tornTabs: TornTabRegistry
	// Tests: whether a connected session's close asks, in place of the stored preference.
	var sshCloseAskOverride: Bool?
	// Whether the main window's inspector column is open: its toolbar toggle, ⌥⌘0 and the
	// tree's Properties set it. Window state, kept across reconnects by MainWindowState.
	@Published public var showInfoPanel = false
	// Every alert and question, one at a time in arrival order (PR25; failures since P15,
	// disk adds since P17, session closes since H42): each shows in its window — the key one
	// for alerts and the start/stop follow-ups, the main window for confirmations, the asking
	// one for a session close. Its own observable: only the windows' presenters watch it.
	// What shows is read below, one kind each, for code and tests; setting an is…Presented
	// false is a dismissal, and the next prompt waiting shows after it.
	public let prompts = PromptCenter()
	public var presentedError: PresentedError? { prompts.current?.kind.error }
	public var isErrorPresented: Bool {
		get { presentedError != nil }
		set { if !newValue, presentedError != nil { dismissCurrentPrompt() } }
	}
	public var pendingForceStart: PendingForceStart? { prompts.current?.kind.forceStart }
	public var isForceStartPresented: Bool {
		get { pendingForceStart != nil }
		set { if !newValue, pendingForceStart != nil { dismissCurrentPrompt() } }
	}
	public var pendingEndProcess: PendingEndProcess? { prompts.current?.kind.endProcess }
	public var isEndProcessPresented: Bool {
		get { pendingEndProcess != nil }
		set { if !newValue, pendingEndProcess != nil { dismissCurrentPrompt() } }
	}
	public var pendingDiskAdd: PendingDiskAdd? { prompts.current?.kind.diskAdd }
	public var isDiskAddPresented: Bool {
		get { pendingDiskAdd != nil }
		set { if !newValue, pendingDiskAdd != nil { dismissCurrentPrompt() } }
	}
	public var pendingTabClose: PendingTabClose? { prompts.current?.kind.tabClose }
	public var isTabClosePresented: Bool {
		get { pendingTabClose != nil }
		set { if !newValue, pendingTabClose != nil { dismissCurrentPrompt() } }
	}
	public var pendingVMDelete: VMInfo? { prompts.current?.kind.deleteVM }
	public var pendingDiskDelete: PendingDiskDelete? { prompts.current?.kind.deleteDisk }
	public var pendingKernelDelete: PendingKernelDelete? { prompts.current?.kind.deleteKernel }
	// Remove Kernel Settings… asks first (H54, K2; +KernelSettings.swift).
	public var pendingKernelClear: PendingKernelClear? { prompts.current?.kind.clearKernel }
	// The Stop menu's Shut Down… (⌘.) and Force Stop… (⌥⌘.) ask first (P26).
	public var pendingStop: PendingStop? { prompts.current?.kind.stop }
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
	@Published public internal(set) var safeSaveInFlight = false

	// MARK: Toasts (VMListViewModel+Toasts.swift)

	// Bottom-right transient toasts (engine warnings/errors, confirmations), observed by the
	// overlay alone (Q10); transfers show as progress cards from OperationsStore instead.
	public let toastCenter = ToastCenter()

	// MARK: List announcer (VMListViewModel+ListAnnouncer.swift)

	// Last state seen per VM, for outcome toasts: diffing the store's list catches changes
	// that arrive via reload (no discrete event) and dedupes doubled events. VM-keyed state,
	// so it follows renames and safe saves like the rest (PR24).
	let announcerMemory = ListAnnouncerMemory()
	var knownStates: [String: VMState] {
		get { announcerMemory.states }
		set { announcerMemory.states = newValue }
	}
	var knownSSH: [String: SSHSnapshot] {
		get { announcerMemory.ssh }
		set { announcerMemory.ssh = newValue }
	}
	// Re-run Address Discovery / Check Connection (F4): the VMs waiting on an answer (each
	// with its timeout) and those that heard one, so even "nothing changed" is said.
	var rediscovering: [String: Task<Void, Never>] = [:]
	var rediscoveryAnswered: Set<String> = []
	// How long a re-run waits before saying the daemon keeps looking (tests shorten it).
	var rediscoveryWait: Duration = .seconds(30)

	// MARK: Renames (VMListViewModel+Actions.swift)

	// Renames sent whose client state hasn't moved yet, old name → new. The daemon announces
	// a rename before it replies, so the list without the old name can land first: whichever
	// of the two arrives first moves the state (T16).
	var renamesInFlight: [String: String] = [:]
	// State moved to a name (a rename, a safe save) that no list has shown yet: the refresh
	// that shows it swaps the torn windows and the selection over.
	var pendingMigrations: [String: String] = [:]
	// Each VM's last kernel-settings write: the next one waits for it (+KernelSettings.swift).
	var kernelWrites: [String: Task<Void, Never>] = [:]
	// Every store of client state keyed by VM name (PR24), walked in one place:
	// migrateClientState for a rename or a safe save, listRefreshed for VMs that left.
	var keyedState: [any VMKeyedState] = []
	// The names the last landed list showed (nil until one has, per connection): a rename
	// made elsewhere is a name a list brings in place of one it drops (T34).
	private var lastListed: Set<String>?

	private var eventTask: Task<Void, Never>?
	private var storeForwarder: AnyCancellable?
	private var installStageForwarder: AnyCancellable?
	private var activeTabReactor: AnyCancellable?
	private var listReactor: AnyCancellable?

	public var selected: VMInfo? {
		selectedName.flatMap { name in vms.first { $0.name == name } }
	}

	// `tornTabs` defaults to the app's shared registry; tests pass their own. `profiles`, the
	// app-scoped terminal profiles, follow their VMs' names (T29); renders may leave it out.
	public init(
		api: MachmanControlling, store: VMStore, operations: OperationsStore,
		terminals: TerminalSessions, previews: PreviewService, canvases: CanvasStateStore,
		tornTabs: TornTabRegistry? = nil, profiles: TerminalProfileStore? = nil
	) {
		self.api = api
		self.store = store
		self.operationsStore = operations
		self.terminals = terminals
		self.previews = previews
		self.canvases = canvases
		self.tornTabs = tornTabs ?? .shared
		keyedState = [terminals, canvases, previews, operations, announcerMemory]
		if let profiles { keyedState.append(profiles) }
		// The list is what views read through this object: forward its changes.
		storeForwarder = store.objectWillChange.sink { [weak self] in
			self?.objectWillChange.send()
		}
		// Progress and layouts are not (P9): the views showing them observe OperationsStore
		// and CanvasStateStore themselves, and the menus follow MenuModel. What this object's
		// own answers read of them is an install's stage (isInstalling, installPhase(for:)'s
		// kind), so only a change of stage is passed on, never a progress tick.
		installStageForwarder = operations.$installPhases
			.map { $0.mapValues(\.kind) }
			.removeDuplicates()
			.dropFirst()
			.sink { [weak self] _ in self?.objectWillChange.send() }
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
		let names = Set(list.map(\.name))
		// A rename this list already shows moves its VM's state first, before the reconcile
		// below would take the old name for a VM gone (T16).
		for (old, new) in renamesInFlight where names.contains(new) && !names.contains(old) {
			renamesInFlight[old] = nil
			migrateClientState(from: old, to: new, .renamed)
		}
		// A rename made elsewhere moves its VM's state the same way (T34), so the selection
		// and torn windows follow it below too.
		migrateRenames(externalRenames(in: list, names: names))
		// Tabs whose port vanished close (tearing down the controller and deselecting the
		// port's row, as every close does).
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
		// Every VM-keyed store forgets the VMs that left — once the announcer has diffed this
		// list against what it last saw. State moved to a name no list has shown yet stays:
		// this list may have been fetched, or a row of it patched, before the move.
		let kept = names.union(pendingMigrations.values)
		for state in keyedState {
			state.forgetVMs(except: kept)
			state.listed(list)
		}
		// The sidebar shows the selected VM's device tree, so something should always be
		// selected while VMs exist (launch, post-delete) — and a selection whose VM is gone
		// falls over to the first. A selection whose state moved to a new name follows it.
		if let name = selectedName {
			if let new = pendingMigrations[name], names.contains(new) {
				select(name: new)
			} else if !kept.contains(name) {
				select(name: list.first?.name)
			}
		} else if let first = list.first {
			select(name: first.name)
		}
		pendingMigrations = pendingMigrations.filter { !names.contains($0.value) }
		lastListed = names
	}

	// Renames made elsewhere (another desktop, a script, Finder while the agent was away,
	// T34), by the created dates the stores recorded. A target is a name this list brought,
	// or a listed name whose recorded date isn't its VM's (that state is stale); a source is
	// a name this list dropped — any absent name on a connection's first list — or such a
	// listed name. Names of this desktop's own moves still in flight are neither: a list
	// from before the move still shows the old name.
	private func externalRenames(in list: [VMInfo], names: Set<String>)
		-> [(from: String, to: String)] {
		var dates: [String: Date] = [:]
		for state in keyedState { dates.merge(state.ownerDates) { recorded, _ in recorded } }
		guard !dates.isEmpty else { return [] }
		let stale = Set(list.compactMap { vm in
			dates[vm.name].flatMap { VMOwnerDates.sameVM($0, vm.created) ? nil : vm.name }
		})
		let moving = Set(pendingMigrations.keys).union(pendingMigrations.values)
		let dropped = lastListed.map { $0.subtracting(names) }
			?? Set(dates.keys).subtracting(names)
		let arrived = names.subtracting(lastListed ?? [])
		return VMOwnerDates.renames(
			in: list, dates: dates, sources: dropped.union(stale).subtracting(moving),
			targets: arrived.union(stale).subtracting(moving))
	}

	// Each pair's client state moves as a rename, every source lifted before any is placed,
	// so names that swap or chain each keep their own VM's state.
	private func migrateRenames(_ pairs: [(from: String, to: String)]) {
		guard !pairs.isEmpty else { return }
		let lifted = pairs.map { (pair: $0, held: "\u{0}renaming \($0.from)") }
		for (pair, held) in lifted {
			for state in keyedState { state.renameVM(from: pair.from, to: held) }
		}
		for (pair, held) in lifted {
			for state in keyedState { state.renameVM(from: held, to: pair.to) }
			pendingMigrations[pair.from] = pair.to
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
			// Discovery answers arrive with no listChanged — refresh the rows ourselves,
			// joining the store's next fetch (P8).
			if rediscovering[vm] != nil { rediscoveryAnswered.insert(vm) }
			store.requestReload()
		case .setupChanged:
			// Guest-setup reports land with no listChanged — same treatment.
			store.requestReload()
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
		presentError(PresentedError(title: "\(action) failed", message: message))
	}

	// An alert whose title is the whole story, not "<action> failed".
	public func present(title: String, message: String) {
		MachmanLogger.log(.interactionError, "\(title): \(message)")
		presentError(PresentedError(title: title, message: message))
	}

	// The same failure showing or waiting already is not asked again.
	private func presentError(_ error: PresentedError) {
		prompts.ask(.error(error)) { shown, new in
			guard case .error(let a) = shown, case .error(let b) = new else { return false }
			return a.title == b.title && a.message == b.message
		}
	}

	func dismissCurrentPrompt() {
		if let id = prompts.current?.id { prompts.dismiss(id) }
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

	// A second drop asked while one shows waits for its own (P17).
	public func askDiskAdd(vm: String, urls: [URL]) {
		guard !urls.isEmpty else { return }
		prompts.ask(.diskAdd(PendingDiskAdd(vm: vm, urls: urls)))
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
		// A window whose VM's state moved to a name this list shows swaps to it (T3): the
		// migration re-keyed the live controller, which the successor window adopts.
		// A window already under a moved-in name the list doesn't show yet stays open.
		let names = Set(list.map(\.name))
		let movedIn = Set(pendingMigrations.values)
		for torn in registry.open where next[torn] == nil {
			if let new = pendingMigrations[torn.vm], names.contains(new) {
				next[torn] = .reopen(as: TornTab(vm: new, tab: torn.tab))
			} else if !movedIn.contains(torn.vm), torn.isStale(in: list) {
				next[torn] = .close
			}
		}
		if registry.orders != next { registry.orders = next }
	}
}
