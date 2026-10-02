//
//  VMListViewModel.swift
//  MachmanDesktopCore
//
//  The client half of the app: view-facing state fed exclusively through MachmanControlling
//  and its event stream. Holds no engine objects — only DTOs, selection, preview images, and
//  install-phase snapshots. Works identically against LocalMachman (in-process) or a future
//  RemoteMachman (daemon).
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
	@Published public var vmName: String = ""
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
	// Pending destructive/choice confirmations, presented as confirmationDialogs by
	// VMNavigationView (the HIG successor to the old modal NSAlerts).
	// One copy-or-reference question for every disk file of one drop, paste or pick.
	public struct PendingDiskAdd: Identifiable {
		public let id = UUID()
		public let vm: String
		public let urls: [URL]   // never empty

		public var title: String {
			urls.count == 1
				? "Add \(urls[0].lastPathComponent)?"
				: "Copy or reference these \(urls.count) files?"
		}

		public var message: String {
			urls.count == 1
				? "Copy \(urls[0].lastPathComponent) into \(vm) (an independent copy that "
					+ "travels with the VM), or reference the original in place?"
				: "Copies travel with \(vm); references use the originals in place."
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
	@Published public private(set) var copyInFlight = false
	// vm.state flips to .starting only when the vmhost's first event lands — 0.5–2 s after
	// the click — so every start affordance would happily double-fire into the daemon in
	// that window. Set synchronously on click, cleared when the request settled and a
	// fresh list was fetched (copyInFlight's shape, per-VM).
	@Published public private(set) var pendingStarts: Set<String> = []
	@Published public var safeSaveRequest: VMInfo?      // non-nil presents SafeSaveSheet
	// File ▸ New VM… asks the main window's toolbar picker to open on its template page;
	// the picker clears it as it opens (VMIndicatorCluster).
	@Published public var newVMChooserRequested = false
	// The Stop menu's Shut Down… (⌘.) and Force Stop… (⌥⌘.) ask first (P26); non-nil
	// presents the question on the main window.
	@Published public var pendingStop: PendingStop?
	@Published public private(set) var safeSaveInFlight = false
	// Bottom-right transient toasts (engine warnings/errors, confirmations). Lifetime is
	// the user's setting; transfers show as progress cards from OperationsStore instead.
	@Published public private(set) var toasts: [MachmanToast] = []

	public static let toastSecondsKey = "MachmanToastSeconds"
	public static let defaultToastSeconds = 4.0
	public static let maxToasts = 5

	private var eventTask: Task<Void, Never>?
	private var storeForwarder: AnyCancellable?
	private var operationsForwarder: AnyCancellable?
	private var canvasForwarder: AnyCancellable?
	private var activeTabReactor: AnyCancellable?
	private var listReactor: AnyCancellable?
	// Last state seen per VM, for outcome toasts: diffing the store's list catches changes
	// that arrive via reload (no discrete event) and dedupes doubled events.
	private var knownStates: [String: VMState] = [:]

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
			// unknown = the daemon could not tell (a vmhost not adopted yet, or one that
			// never answered): whatever it turns out to be was already so.
			guard previous != .unknown else { continue }
			switch vm.state {
			case .running:
				pushToast(symbol: MachmanSymbols.start, message: "\(vm.name) started")
			case .stopped where previous == .running || previous == .stopping:
				pushToast(symbol: MachmanSymbols.shutDown, message: "\(vm.name) stopped")
			case .error:
				pushProblem(
					symbol: MachmanSymbols.warning, message: "\(vm.name) hit an error",
					tint: MachmanColors.warning, vm: vm.name, detail: "Stopped with an error",
					severity: .failure)
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
		var setupReportAt: Date?
		var setupRun: SetupRun?
	}

	// What a setup RUN decided, as opposed to what any report re-probes (features, consoles,
	// automounts, OS facts): a boot-time refresh replays the last run's outcome unchanged,
	// so only a change here is a run worth a toast.
	private struct SetupRun: Equatable {
		var installed: Bool?
		var status: String?
		var note: String?
		var errors: [GuestSetupError]?
		var notes: [GuestSetupNote]?
		var scriptVersion: Int?

		init?(_ setup: GuestSetupInfo?) {
			guard let setup else { return nil }
			installed = setup.installed
			status = setup.lastRunStatus
			note = setup.lastRunNote
			errors = setup.errors
			notes = setup.notes
			scriptVersion = setup.scriptVersion
		}
	}
	private var knownSSH: [String: SSHSnapshot] = [:]
	// Re-run Address Discovery / Check Connection (F4): the VMs waiting on an answer (each
	// with its timeout) and those that heard one, so even "nothing changed" is said.
	private var rediscovering: [String: Task<Void, Never>] = [:]
	private var rediscoveryAnswered: Set<String> = []
	// How long a re-run waits before saying the daemon keeps looking (tests shorten it).
	var rediscoveryWait: Duration = .seconds(30)

	public static func sshWaitToastKey(_ vm: String) -> String { "ssh-wait-\(vm)" }
	public static func rediscoveryToastKey(_ vm: String) -> String { "rediscover-\(vm)" }
	public static func logToastKey(_ text: String) -> String { "log:" + text }

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
				reverseState: vm.ssh?.reverseState ?? .none,
				setupReportAt: vm.setup?.lastReportAt,
				setupRun: SetupRun(vm.setup))
			let previous = knownSSH[vm.name]
			knownSSH[vm.name] = now
			// A re-run discovery that heard back says what it found, unchanged or not.
			if rediscovering[vm.name] != nil, rediscoveryAnswered.contains(vm.name),
				let address = now.address {
				endRediscovery(vm.name)
				if previous?.address == address {
					pushToast(
						symbol: MachmanSymbols.network,
						message: "\(vm.name) is still at \(address)",
						key: Self.rediscoveryToastKey(vm.name))
				}   // else the "answered" toast below says it
			}
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
			// A setup run landed. One toast per run: the unified (v3) report speaks for
			// the whole run; the SSH-only phrasing survives for v2 guests, whose reports
			// carry no setup half. Every boot re-sends the report: a refresh that changed
			// only what it probes, not the run's outcome, stays quiet.
			let setupLanded = now.setupReportAt != nil
				&& previous.setupReportAt != now.setupReportAt
				&& previous.setupRun != now.setupRun
			if setupLanded {
				if vm.setup?.installed == false {
					pushToast(
						symbol: MachmanSymbols.deviceGuestSetup,
						message: "\(vm.name): guest setup removed")
				} else if let status = vm.setup?.lastRunStatus, status != "ok" {
					pushProblem(
						symbol: MachmanSymbols.warning,
						message: "\(vm.name): guest setup \(status) — details in the "
							+ "inspector",
						tint: MachmanColors.warning, vm: vm.name,
						detail: "Guest setup \(status) — details in the inspector",
						severity: .warning)
				} else {
					pushToast(
						symbol: MachmanSymbols.deviceGuestSetup,
						message: "\(vm.name): guest setup complete")
				}
			} else if vm.setup?.lastReportAt == nil, let stamp = now.lastReportAt,
				previous.lastReportAt != stamp {
				let user = vm.ssh?.guestUser ?? "the guest"
				let os = vm.ssh?.guestOS.map { " (\($0))" } ?? ""
				if let status = vm.ssh?.lastRunStatus, status != "ok" {
					let note = vm.ssh?.lastRunNote.map { " — \($0)" } ?? ""
					pushProblem(
						symbol: MachmanSymbols.warning,
						message: "\(vm.name): SSH setup \(status)\(note)",
						tint: MachmanColors.warning, vm: vm.name,
						detail: "SSH setup \(status)\(note)", severity: .warning)
				} else {
					pushToast(
						symbol: MachmanSymbols.deviceSSHSetup,
						message: "\(vm.name): SSH set up for \(user)\(os)")
				}
			}
			if previous.reverseState != .pending, now.reverseState == .pending {
				pushProblem(
					symbol: MachmanSymbols.deviceSSHSetup,
					message: "\(vm.name) asks to log in to this Mac — approve it in the "
						+ "SSH section",
					tint: MachmanColors.warning, vm: vm.name,
					detail: "Asks to log in to this Mac — approve it in the SSH section",
					severity: .warning)
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
		// …nor a re-run discovery to wait on.
		let running = Set(list.filter { $0.state.isRunning }.map(\.name))
		for name in rediscovering.keys where !running.contains(name) {
			endRediscovery(name)
		}
	}

	// The spinner goes up before the RPC: an answer can beat its reply.
	private func beginRediscovery(_ name: String) {
		rediscovering[name]?.cancel()
		rediscoveryAnswered.remove(name)
		pushToast(
			symbol: MachmanSymbols.network, message: "Looking for \(name)'s address…",
			key: Self.rediscoveryToastKey(name), spinner: true, sticky: true)
		let wait = rediscoveryWait
		rediscovering[name] = Task { [weak self] in
			try? await Task.sleep(for: wait)
			guard !Task.isCancelled, let self else { return }
			self.rediscovering[name] = nil
			self.rediscoveryAnswered.remove(name)
			self.pushToast(
				symbol: MachmanSymbols.network,
				message: "No address for \(name) yet — Machman keeps looking",
				key: Self.rediscoveryToastKey(name))
		}
	}

	// The wait is over; its toast is replaced by whoever says how it ended.
	private func endRediscovery(_ name: String) {
		rediscovering.removeValue(forKey: name)?.cancel()
		rediscoveryAnswered.remove(name)
		dismissToast(key: Self.rediscoveryToastKey(name))
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
				// Keyed by its text: a warning repeated while its toast shows restarts that
				// toast instead of stacking another copy (P15).
				let text = "\(vm.map { "\($0): " } ?? "")\(message)"
				pushToast(
					symbol: MachmanSymbols.warning, message: text, tint: MachmanColors.warning,
					key: Self.logToastKey(text))
				// The toast goes in seconds; the activity list keeps the whole text (F6).
				activity.record(.engineLog(vm: vm, level: level, message: message, at: Date()))
			}
		case .copyProgress:
			break   // legacy wire event; the operation cards carry all copy progress
		case .operationChanged:
			// The operations UI (progress cards) lands with the desktop overhaul; until
			// then the legacy copyProgress events above cover the same transfers.
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

	// MARK: - Error surface

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

	// Toasts the pointer rests on stay until it leaves, then live a fresh lifetime (F6), so a
	// long warning can be read; each timed toast's expiry is tracked to restart it.
	private var heldToasts: Set<UUID> = []
	private var toastExpiries: [UUID: Task<Void, Never>] = [:]
	// Tests shorten a toast's life without touching the user's setting.
	var toastLifetimeOverride: Duration?

	private var toastLifetime: Duration {
		if let toastLifetimeOverride { return toastLifetimeOverride }
		let stored = UserDefaults.standard.double(forKey: Self.toastSecondsKey)
		return .seconds(stored > 0 ? stored : Self.defaultToastSeconds)
	}

	// A bottom-right toast; lifetime comes from the user's setting. A `key` makes it a
	// named slot: pushing the same key replaces what is showing IN PLACE, so a state that
	// moves (waiting → ready) reads as one toast changing rather than three piling up.
	// `spinner` shows an indeterminate indicator instead of the symbol, and `sticky` skips
	// the timer entirely — for waits that end with another push.
	public func pushToast(
		symbol: String, message: String, tint: Color? = nil,
		key: String? = nil, spinner: Bool = false, sticky: Bool = false
	) {
		let toast = MachmanToast(
			symbol: symbol, message: message, tint: tint,
			key: key, spinner: spinner, sticky: sticky)
		if let key, let existing = toasts.firstIndex(where: { $0.key == key }) {
			let replaced = toasts[existing].id
			let wasHeld = heldToasts.contains(replaced)
			toasts[existing] = toast
			forgetToast(replaced)
			// The pointer still rests on the slot: the hold moves to what replaced it.
			if wasHeld { heldToasts.insert(toast.id) }
		} else {
			toasts.append(toast)
			// A burst keeps the newest few: the oldest timed toast goes first, waits stay.
			while toasts.count > Self.maxToasts,
				let oldest = toasts.firstIndex(where: { !$0.sticky }) {
				forgetToast(toasts.remove(at: oldest).id)
			}
		}
		guard !sticky else { return }
		scheduleToastExpiry(toast.id)
	}

	// The overlay's hover: a held toast outlives its timer; letting go restarts it in full.
	public func holdToast(_ id: UUID, _ held: Bool) {
		if held {
			heldToasts.insert(id)
		} else if heldToasts.remove(id) != nil,
			toasts.contains(where: { $0.id == id && !$0.sticky }) {
			scheduleToastExpiry(id)
		}
	}

	private func scheduleToastExpiry(_ id: UUID) {
		toastExpiries[id]?.cancel()
		let lifetime = toastLifetime
		toastExpiries[id] = Task { [weak self] in
			try? await Task.sleep(for: lifetime)
			guard !Task.isCancelled, let self else { return }
			self.toastExpiries[id] = nil
			// Held: the release starts a fresh lifetime.
			guard !self.heldToasts.contains(id) else { return }
			self.toasts.removeAll { $0.id == id }
		}
	}

	// A toast that left the stack by any other way than its own timer.
	private func forgetToast(_ id: UUID) {
		toastExpiries.removeValue(forKey: id)?.cancel()
		heldToasts.remove(id)
	}

	// Settings files a store could not read at launch and set aside as a .bak (P19): one
	// toast each, the first time a view model asks (a reconnect's never repeats it).
	public func announceSetAsideSettings(_ stores: [any SetAsideReporting]) {
		for store in stores {
			guard let file = store.takeSetAsideNotice() else { continue }
			pushToast(
				symbol: MachmanSymbols.info,
				message: "Couldn't read your \(file.what) — kept them as "
					+ "\(file.backup.lastPathComponent).")
		}
	}

	// Retire a named slot without replacing it (the wait ended in nothing worth saying).
	public func dismissToast(key: String) {
		for toast in toasts where toast.key == key { forgetToast(toast.id) }
		toasts.removeAll { $0.key == key }
	}

	public func cancelOperation(id: String) {
		Task { [weak self] in
			do {
				try await self?.api.cancelOperation(id: id)
			} catch let error as MachmanError where error.code == .notFound {
				// It ended meanwhile; its card already shows how.
			} catch {
				self?.present(error, while: "Canceling the operation")
			}
		}
	}

	public func present(_ error: Error, while action: String) {
		present(message: Self.message(for: error), while: action)
	}

	// localizedDescription on a non-LocalizedError is NSError-bridge boilerplate ("The
	// operation couldn't be completed…"); String(describing:) picks up the connection
	// errors' CustomStringConvertible instead.
	static func message(for error: Error) -> String {
		(error as? LocalizedError)?.errorDescription ?? String(describing: error)
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
		vmName = name ?? ""
		previews.setVisible(name.map { [$0] } ?? [])
	}

	// MARK: - Actions

	public func toggleRun(_ vm: VMInfo) {
		if vm.state.isRunning {
			stopVM(vm.name)
		} else {
			startPolicyDriven(vm)
		}
	}

	public func isStartPending(_ name: String) -> Bool {
		pendingStarts.contains(name)
	}

	// The low-level start with exact options. Affordances never call it: they go through
	// startPolicyDriven (VMListViewModel+Start.swift), which applies the VM's start policy.
	// Only the MAC-conflict retry, which repeats a refused start with force, needs it.
	public func startVM(
		_ name: String, headless: Bool = false, force: Bool = false, safe: Bool = false
	) {
		guard !pendingStarts.contains(name) else { return }
		pendingStarts.insert(name)
		Task { [weak self] in
			defer { self?.pendingStarts.remove(name) }
			do {
				try await self?.api.start(
					vm: name,
					options: StartOptions(openWindow: !headless, force: force, safe: safe))
				// A fresh list before the flag drops, so the affordances flip straight
				// from pending to the running controls, never through a stale Start.
				await self?.reload()
			} catch let error as MachmanError where error.code == .macConflict {
				// Not a dead end: the same start succeeds with force, so offer it.
				self?.pendingForceStart = PendingForceStart(
					name: name, headless: headless, safe: safe, message: error.message)
			} catch {
				self?.present(error, while: "Starting \(name)")
			}
		}
	}

	public func openWindow(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.openWindow(vm: name)
			} catch {
				self?.present(error, while: "Opening the \(name) window")
			}
		}
	}

	public func closeWindow(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.closeWindow(vm: name)
			} catch {
				self?.present(error, while: "Closing the \(name) window")
			}
		}
	}

	public func stopVM(_ name: String, mode: StopMode = .force) {
		Task { [weak self] in
			do {
				try await self?.api.stop(vm: name, mode: mode)
			} catch {
				self?.present(error, while: "Stopping \(name)")
			}
		}
	}

	public func createVM(template: String? = nil) async -> String? {
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
	public func deleteVM(_ vm: VMInfo) {
		pendingVMDelete = vm
	}

	public func performDeleteVM(_ vm: VMInfo) {
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
	public func requestRemoveDisk(_ name: String, disk: DiskInfo) {
		if disk.owned == true {
			pendingDiskDelete = PendingDiskDelete(vm: name, disk: disk)
		} else {
			removeDisk(name, diskID: disk.id)
		}
	}

	public func requestDeleteKernel(_ name: String, path: String, fileName: String) {
		pendingKernelDelete = PendingKernelDelete(vm: name, path: path, fileName: fileName)
	}

	public func rename(from oldName: String, to newName: String) async -> Bool {
		await rename(from: oldName, to: newName, refused: nil)
	}

	// `refused` takes a refusal to the field that asked, instead of an alert (PR8).
	func rename(
		from oldName: String, to newName: String, refused: (@MainActor (String) -> Void)?
	) async -> Bool {
		do {
			try await api.renameVM(named: oldName, to: newName)
			// Migrate open terminal tabs BEFORE reload()'s reconcile sees the new name (else the
			// old-keyed session would look like a vanished VM and its terminals get closed).
			migrateClientState(from: oldName, to: newName)
			await reload()
			select(name: newName)
			reopenTornWindows(from: oldName, to: newName)
			return true
		} catch {
			refuse(error, while: "Renaming \(oldName)", to: refused)
			vmName = oldName
			return false
		}
	}

	// A VM's client-side state follows it to a new name: live terminals and ssh sessions,
	// the canvas layout and the last preview frame.
	private func migrateClientState(from old: String, to new: String) {
		terminals.renameVM(from: old, to: new)
		canvases.renameVM(from: old, to: new)
		previews.renameVM(from: old, to: new)
	}

	// Torn windows cannot re-key their birth payload — swap them (T3): each old-named
	// window is ordered to reopen as the new name, adopting the live controller the
	// migration re-keyed. Posted AFTER the reload: a rename's reconcile just marked these
	// payloads close (old name gone from the fresh list), and this overwrite lands in the
	// same main-actor job, before any window can act on it.
	private func reopenTornWindows(from old: String, to new: String) {
		let registry = tornTabs
		for torn in registry.open where torn.vm == old {
			registry.orders[torn] = .reopen(as: TornTab(vm: new, tab: torn.tab))
		}
	}

	public func setHardware(
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

	// The one rename flow (tree rename-in-place + the VM inspector's name field): trimmed,
	// checked against the VM-name rule and the list before the daemon sees it, migrating
	// terminal/canvas/preview/profile state on success. `reverted` runs when the typed name
	// is not applied (blank, unchanged, refused here or by the daemon), so a field can drop
	// it instead of showing a name the VM doesn't have. `refused` (last, so a trailing
	// closure still means `reverted`) takes a refusal to the field instead of an alert.
	public func requestRename(
		_ vm: VMInfo, to typed: String, profiles: TerminalProfileStore,
		reverted: @escaping @MainActor () -> Void = {},
		refused: (@MainActor (String) -> Void)? = nil
	) {
		let old = vm.name
		let newName = NameRule.vmName.trimmed(typed)
		guard !newName.isEmpty, newName != old else {
			reverted()
			return
		}
		if let problem = newVMNameProblem(newName) {
			refuse(problem, while: "Renaming \(old)", to: refused)
			reverted()
			return
		}
		Task { [weak self] in
			guard let self = self else { return }
			if await self.rename(from: old, to: newName, refused: refused) {
				profiles.renameVM(from: old, to: newName)
				self.log(message: "Renamed \(old) to \(newName)")
				self.pushToast(
					symbol: MachmanSymbols.rename,
					message: "Renamed to \u{201C}\(newName)\u{201D}")
			} else {
				reverted()
			}
		}
	}

	public func requestCopy(_ vm: VMInfo) {
		// The sheet's space hint reads capabilities.freeDiskBytes, fetched once at connect —
		// refresh so the figure isn't sessions old.
		Task { [weak self] in
			await self?.store.refreshCapabilities()
		}
		copyRequest = vm
	}

	public func copyVM(
		_ name: String, newName: String, diskIDs: [String], mountIDs: [String]? = nil
	) {
		guard !copyInFlight else { return }
		copyInFlight = true
		copyRequest = nil   // the sheet closes now; the corner card tracks the copy
		Task { [weak self] in
			do {
				let copy = try await self?.api.copyVM(
					vm: name, newName: newName, diskIDs: diskIDs, mountIDs: mountIDs,
					regenerateMAC: true)
				self?.copyInFlight = false
				await self?.reload()
				if let copy { self?.select(name: copy.name) }
			} catch {
				self?.copyInFlight = false
				self?.present(error, while: "Duplicating \(name)")
			}
		}
	}

	public func defaultCopyName(for name: String) -> String {
		let base = "\(name) copy"
		guard hasVM(base) else { return base }
		var n = 2
		while hasVM("\(base) \(n)") { n += 1 }
		return "\(base) \(n)"
	}

	public func askDiskAdd(vm: String, urls: [URL]) {
		guard !urls.isEmpty else { return }
		diskAddQueue.enqueue(PendingDiskAdd(vm: vm, urls: urls))
	}

	// A batch copies one file after another: one disk-heavy copy at a time, and a daemon from
	// before wave 2 picked each name when its copy started. A failed file gets its own
	// alert and the rest carry on.
	public func importDisks(_ name: String, paths: [String]) {
		Task { [weak self] in
			for path in paths {
				guard let api = self?.api else { return }
				do {
					_ = try await api.importDisk(vm: name, path: path)
				} catch {
					let file = (path as NSString).lastPathComponent
					self?.present(error, while: "Importing \(file) into \(name)")
				}
			}
		}
	}

	public func importDisk(_ name: String, path: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.importDisk(vm: name, path: path)
			} catch {
				self?.present(error, while: "Importing a disk into \(name)")
			}
		}
	}

	public func promoteDisk(_ name: String, diskID: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.promoteDisk(vm: name, diskID: diskID)
			} catch {
				self?.present(error, while: "Promoting a disk on \(name)")
			}
		}
	}

	// The disk id derives from the name, so a successful rename repoints a selection that
	// was on the old id (the inspector would otherwise go blank). `refused` takes a refusal
	// to the field instead of an alert.
	public func renameDisk(
		_ name: String, diskID: String, newName: String,
		refused: (@MainActor (String) -> Void)? = nil
	) {
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
				self?.refuse(error, while: "Renaming a disk", to: refused)
			}
		}
	}

	public func setMountTag(
		_ name: String, mountID: String, tag: String,
		refused: (@MainActor (String) -> Void)? = nil
	) {
		Task { [weak self] in
			do {
				_ = try await self?.api.setMountTag(vm: name, mountID: mountID, tag: tag)
				self?.pushToast(
					symbol: MachmanSymbols.rename,
					message: "Mount tag changed to \u{201C}\(tag)\u{201D}")
			} catch {
				self?.refuse(error, while: "Changing a mount tag", to: refused)
			}
		}
	}

	public func setMountKind(_ name: String, mountID: String, kind: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.setMountKind(vm: name, mountID: mountID, kind: kind)
			} catch {
				self?.present(error, while: "Changing a mount's kind")
			}
		}
	}

	// The file's path changes with its tag — repoint a selection that was on the old path.
	// `refused` takes a refusal to the field instead of an alert.
	public func renameKernelTag(
		_ name: String, path: String, tag: String,
		refused: (@MainActor (String) -> Void)? = nil
	) {
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
				self?.refuse(error, while: "Renaming a kernel file", to: refused)
			}
		}
	}

	public func resizeDisk(_ name: String, diskID: String, sizeBytes: UInt64) {
		Task { [weak self] in
			do {
				_ = try await self?.api.resizeDisk(
					vm: name, diskID: diskID, sizeBytes: sizeBytes)
				self?.pushToast(
					symbol: MachmanSymbols.diskSize,
					message: "Disk grown to \(ByteSize.display(sizeBytes))")
			} catch {
				self?.present(error, while: "Growing a disk")
			}
		}
	}

	public func setDiskSafety(_ name: String, diskID: String, safe: Bool) {
		Task { [weak self] in
			do {
				try await self?.api.setSafety(vm: name, disks: [diskID: safe], mounts: nil)
			} catch {
				self?.present(error, while: "Updating disk safety")
			}
		}
	}

	public func setMountSafety(_ name: String, mountID: String, safe: Bool) {
		Task { [weak self] in
			do {
				try await self?.api.setSafety(vm: name, disks: nil, mounts: [mountID: safe])
			} catch {
				self?.present(error, while: "Updating mount safety")
			}
		}
	}

	public func requestSafeSave(_ vm: VMInfo) {
		safeSaveRequest = vm
	}

	public func defaultSafeSaveName(for name: String) -> String {
		let base = "\(name) saved"
		guard hasVM(base) else { return base }
		var n = 2
		while hasVM("\(base) \(n)") { n += 1 }
		return "\(base) \(n)"
	}

	public func safeSave(_ name: String, to newName: String) {
		guard !safeSaveInFlight else { return }
		safeSaveInFlight = true
		Task { [weak self] in
			do {
				let saved = try await self?.api.safeSave(vm: name, to: newName)
				// The run continues as the new VM (the daemon re-keys the live host and keeps
				// the original, stopped), so its terminals, sessions, layout, torn windows and
				// last frame go with it — as a rename's do. The original starts fresh and
				// connects anew when it is started (T17).
				if let saved { self?.migrateClientState(from: name, to: saved.name) }
				self?.safeSaveInFlight = false
				self?.safeSaveRequest = nil        // item binding dismisses the sheet
				await self?.reload()
				if let saved {
					self?.select(name: saved.name)
					self?.reopenTornWindows(from: name, to: saved.name)
				}
			} catch {
				self?.safeSaveInFlight = false
				self?.safeSaveRequest = nil        // dismiss first; alert isn't sheet-blocked
				self?.present(error, while: "Saving \(name) as a new VM")
			}
		}
	}

	public func setStartPolicy(_ name: String, policy: StartPolicy) {
		Task { [weak self] in
			do {
				try await self?.api.setStartPolicy(vm: name, policy: policy)
			} catch {
				self?.present(error, while: "Updating run defaults for \(name)")
			}
		}
	}

	public func regenerateMAC(_ name: String) {
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
	public func installRosetta() {
		Task { [weak self] in
			do {
				try await self?.api.installRosetta()
				await self?.store.refreshCapabilities()
			} catch {
				self?.present(error, while: "Installing Rosetta")
			}
		}
	}

	public func clampMemory(_ bytes: UInt64, floor: UInt64) -> UInt64 {
		ByteSize.clampMemory(bytes, floor: floor, capabilities: capabilities)
	}

	public func addDisk(_ name: String, _ disk: NewDisk) {
		Task { [weak self] in
			do {
				try await self?.api.addDisk(vm: name, disk)
				self?.pushToast(symbol: MachmanSymbols.diskStorage, message: "Added disk")
			} catch {
				self?.present(error, while: "Adding a disk")
			}
		}
	}

	// References for a batch, one toast for all of them.
	public func addDisks(_ name: String, _ disks: [NewDisk]) {
		Task { [weak self] in
			var added = 0
			for disk in disks {
				guard let api = self?.api else { return }
				do {
					try await api.addDisk(vm: name, disk)
					added += 1
				} catch {
					let file = disk.path.map { ($0 as NSString).lastPathComponent }
					self?.present(error, while: "Adding \(file ?? "a disk")")
				}
			}
			guard added > 0 else { return }
			self?.pushToast(
				symbol: MachmanSymbols.diskStorage,
				message: added == 1 ? "Added disk" : "Added \(added) disks")
		}
	}

	public func removeDisk(_ name: String, diskID: String) {
		Task { [weak self] in
			do {
				try await self?.api.removeDisk(vm: name, diskID: diskID)
				self?.pushToast(symbol: MachmanSymbols.diskStorage, message: "Removed disk")
			} catch {
				self?.present(error, while: "Removing a disk")
			}
		}
	}

	public func addMount(_ name: String, path: String, tag: String, kind: String? = nil) {
		// Every drop, paste and picker passes the folder's name: one the mount-tag rule
		// refuses (.config, a:b) mounts under a cleaned tag the user can rename.
		let rule = NameRule.mountTag
		let tag = rule.problem(rule.trimmed(tag)) == nil
			? tag : rule.suggestion(from: tag, fallback: "share")
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

	public func removeMount(_ name: String, mountID: String) {
		Task { [weak self] in
			do {
				try await self?.api.removeMount(vm: name, mountID: mountID)
				self?.pushToast(symbol: MachmanSymbols.mount, message: "Removed mount")
			} catch {
				self?.present(error, while: "Removing a mount point")
			}
		}
	}

	public func addDevice(_ name: String, kind: DeviceKind) {
		Task { [weak self] in
			do {
				_ = try await self?.api.addDevice(vm: name, kind: kind)
				self?.pushToast(
					symbol: kind.displaySymbol, message: "Added \(kind.displayLabel)")
			}
			catch { self?.present(error, while: "Adding a device") }
		}
	}

	public func removeDevice(_ name: String, kind: DeviceKind) {
		Task { [weak self] in
			do {
				_ = try await self?.api.removeDevice(vm: name, kind: kind)
				self?.pushToast(
					symbol: kind.displaySymbol, message: "Removed \(kind.displayLabel)")
			}
			catch { self?.present(error, while: "Removing a device") }
		}
	}

	public func updateDevice(_ name: String, device: DeviceInfo) {
		Task { [weak self] in
			do { _ = try await self?.api.updateDevice(vm: name, device: device) }
			catch { self?.present(error, while: "Updating a device") }
		}
	}

	// MARK: - SSH (1.0.5)

	public func setSSHIntegration(_ name: String, enabled: Bool) {
		Task { [weak self] in
			do {
				_ = try await self?.api.setSSH(
					vm: name, integrationEnabled: enabled, reverseApproved: nil, alias: nil)
			}
			catch { self?.present(error, while: "Updating the SSH alias") }
		}
	}

	// An empty alias resets the VM to its default "<vm>.machman" name.
	public func setSSHAlias(_ name: String, alias: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.setSSH(
					vm: name, integrationEnabled: nil, reverseApproved: nil, alias: alias)
			}
			catch { self?.present(error, while: "Renaming the SSH alias") }
		}
	}

	public func setSSHReverseApproved(_ name: String, approved: Bool) {
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

	// Re-run Address Discovery and Check Connection: a spinner toast, then what it found —
	// even an unchanged address (F4).
	public func refreshSSH(_ name: String) {
		beginRediscovery(name)
		Task { [weak self] in
			do {
				try await self?.api.refreshSSH(vm: name)
			} catch {
				self?.endRediscovery(name)
				self?.present(error, while: "Refreshing the SSH address")
			}
		}
	}

	public func resetSSH(_ name: String) {
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

	public func resetSetup(_ name: String) {
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

	// The Allow-reinstall toggle made real: serving on demand, clean share otherwise.
	public func setSetupServed(_ name: String, serve: Bool) {
		Task { [weak self] in
			do { _ = try await self?.api.setSetupServed(vm: name, serve: serve) }
			catch { self?.present(error, while: "Updating the setup payload") }
		}
	}

	// Batch enable/disable everything in the tree selection that carries the flag
	// (multi-select context menus + the multi-selection inspector).
	public func setSelectionEnabled(_ enabled: Bool, vm: VMInfo) {
		// Only what still exists (T15): a stale selection must not send gone ids.
		let current = vms.first { $0.name == vm.name } ?? vm
		var disks: [String: Bool] = [:]
		var mounts: [String: Bool] = [:]
		var console: [String: Bool] = [:]
		var uart: [String: Bool] = [:]
		let live = Self.liveNodes(
			treeSelection, in: current, openSessions: openSSHSessions(vm: current.name))
		for node in live {
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
				if var device = current.devices?.first(where: { $0.kind == kind }) {
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
	public func setEnabled(
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

	public func addConsolePort(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.addConsolePort(vm: name)
				self?.pushToast(
					symbol: MachmanSymbols.serialConsole, message: "Added console port")
			}
			catch { self?.present(error, while: "Adding a console port") }
		}
	}

	public func removeConsolePort(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.removeConsolePort(vm: name)
				self?.pushToast(
					symbol: MachmanSymbols.serialConsole, message: "Removed console port")
			}
			catch { self?.present(error, while: "Removing a console port") }
		}
	}

	public func addUartPort(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.addUartPort(vm: name)
				self?.pushToast(symbol: MachmanSymbols.serialUart, message: "Added UART port")
			}
			catch { self?.present(error, while: "Adding a UART port") }
		}
	}

	public func removeUartPort(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.removeUartPort(vm: name)
				self?.pushToast(
					symbol: MachmanSymbols.serialUart, message: "Removed UART port")
			}
			catch { self?.present(error, while: "Removing a UART port") }
		}
	}

	public func promoteKernel(_ name: String, role: KernelRole, sourcePath: String, tag: String) {
		Task { [weak self] in
			do {
				_ = try await self?.api.promoteKernelFile(
					vm: name, role: role, sourcePath: sourcePath, tag: tag)
			} catch {
				self?.present(error, while: "Promoting a kernel file")
			}
		}
	}

	public func deleteKernel(_ name: String, path: String) {
		Task { [weak self] in
			do { _ = try await self?.api.deleteKernelFile(vm: name, path: path) }
			catch { self?.present(error, while: "Deleting a kernel file") }
		}
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

	public func setSerialLogging(
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

	public func setKernelBoot(_ name: String, enabled: Bool) async -> Bool {
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
	public func setActiveKernelFile(_ vm: VMInfo, role: KernelRole, path: String?) {
		var settings = vm.boot.kernel
			?? KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "")
		switch role {
		case .kernel: settings.kernelPath = path ?? ""
		case .initramfs: settings.initrdPath = path
		case .unknown: return   // decode fallback only — the tree never builds it
		}
		updateKernelSettings(vm.name, settings)
	}

	public func setKernelOverride(
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

	public func updateKernelSettings(_ name: String, _ settings: KernelSettings) {
		Task { [weak self] in
			do {
				try await self?.api.updateKernelSettings(vm: name, settings)
			} catch {
				self?.present(error, while: "Saving kernel settings")
			}
		}
	}

	public func startInstall(_ name: String, source: InstallSource) {
		Task { [weak self] in
			do {
				try await self?.api.startMacInstall(vm: name, source: source)
			} catch {
				self?.present(error, while: "Starting the macOS install")
			}
		}
	}

	public func cancelInstall(_ name: String) {
		Task { [weak self] in
			do {
				try await self?.api.cancelMacInstall(vm: name)
			} catch {
				self?.present(error, while: "Canceling the macOS install")
			}
		}
	}

}
