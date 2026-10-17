//
//  TerminalSessions.swift
//  MachmanDesktopCore
//
//  The live terminal controllers behind terminal tabs, keyed (vm, tab). Pure controller
//  lifecycle — WHICH tabs exist and which is active lives in CanvasStateStore (the canvas
//  layout); this registry only creates, connects, reloads, and tears down terminals on
//  demand. App-scoped, so controllers (and their transcripts) survive VM navigation and
//  daemon reconnects; a controller lives exactly as long as its tab is open. Controllers come
//  from an injected factory (the app's is SwiftTerm-backed, tests' record their calls).
//  One registry keyed by the tab: a serial port and an ssh session share every step of the
//  lifecycle (deferred creation, drop, reconcile, rename) and differ only in how they
//  connect, so a third transport is a new VMPaneTab case plus its connect closure.
//

import Foundation
import Combine
import MachmanAPI
import MachmanUI

@MainActor
public final class TerminalSessions: ObservableObject {
	// Not published per-keystroke: views observe each controller's own @Published
	// `connected`; objectWillChange fires when a controller appears or disappears. The
	// config tab has no terminal and is never a key here.
	private var live: [String: [VMPaneTab: any TerminalController]] = [:]
	// Tabs whose controller is being created on a deferred runloop turn (so the spinner
	// shows and we don't schedule creation twice).
	private struct PendingKey: Hashable {
		let vm: String
		let tab: VMPaneTab
	}
	private var creating: Set<PendingKey> = []
	private let makeController: @MainActor (TerminalProfile) -> any TerminalController
	// Per tab, the live settings this registry last gave its controller (made, reloaded or
	// re-applied with), so a store change that leaves a tab's live settings alone applies
	// nothing to it (P38).
	private var appliedLive: [String: [VMPaneTab: TerminalLiveSettings]] = [:]
	private var profileWatch: AnyCancellable?
	private weak var followed: TerminalProfileStore?
	// objectWillChange fires before the change lands: read it a turn later, once however
	// many fields changed in this one.
	private lazy var reapply = NextTurnCoalescer { [weak self] in
		guard let self, let profiles = self.followed else { return }
		self.reapplyLiveProfiles(profiles)
	}

	public init(makeController: @escaping @MainActor (TerminalProfile) -> any TerminalController) {
		self.makeController = makeController
	}

	public func controller(for tab: VMPaneTab, vm: String) -> (any TerminalController)? {
		live[vm]?[tab]
	}

	public func controller(vm: String, ref: SerialPortRef) -> (any TerminalController)? {
		controller(for: .terminal(ref), vm: vm)
	}

	// The deferred-creation shape every transport shares: the tab + spinner paint first and
	// the controller is made on a later runloop turn (AppKit view creation is main-thread-
	// bound — deferral, not backgrounding, but the click stays instant). `stillWanted`
	// re-checks on that turn: the tab may have closed. `start` connects the new controller.
	private func create(
		_ tab: VMPaneTab, vm: String, profile: TerminalProfile,
		stillWanted: @escaping @MainActor () -> Bool,
		start: @escaping @MainActor (any TerminalController) -> Void
	) {
		guard live[vm]?[tab] == nil else { return }
		let key = PendingKey(vm: vm, tab: tab)
		guard !creating.contains(key) else { return }
		creating.insert(key)
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			self.creating.remove(key)
			guard stillWanted() else { return }
			let c = self.makeController(profile)
			self.live[vm, default: [:]][tab] = c
			self.appliedLive[vm, default: [:]][tab] = profile.liveSettings
			start(c)
			self.objectWillChange.send()   // swap the spinner for the terminal
		}
	}

	// Make sure a serial tab's controller exists and is connected, ready to render (created
	// on a later runloop turn — see create). Idempotent per tab; also (re)connects an
	// existing controller whose socket reappeared.
	public func ensureController(
		vm: String, ref: SerialPortRef, socketPath: String?, profile: TerminalProfile,
		stillWanted: @escaping @MainActor () -> Bool = { true }
	) {
		if let c = live[vm]?[.terminal(ref)] {
			if let path = socketPath, !c.connected { c.connect(path: path) }
			return
		}
		create(.terminal(ref), vm: vm, profile: profile, stillWanted: stillWanted) { c in
			if let path = socketPath { c.connect(path: path) }
		}
	}

	// A serial tab's own Reconnect, from its banner: the same controller, so the scrollback
	// stays, with Machman's line marking where the socket's replay of recent output starts. A
	// connected tab is left alone; a refused one gets no line (it didn't reconnect).
	public func reconnectSerial(vm: String, ref: SerialPortRef, socketPath: String) {
		guard let c = live[vm]?[.terminal(ref)], !c.connected else { return }
		c.connect(path: socketPath)
		noteReconnected(c)
	}

	// After a connect that worked. Output reaches the terminal on a later main-queue turn, so
	// the line still lands before the first of it.
	private func noteReconnected(_ c: any TerminalController) {
		guard c.connected else { return }
		c.note("reconnected " + Date().formatted(date: .omitted, time: .shortened))
	}

	// Tear down a tab's controller: tab closed, port removed, or VM deleted. An ssh tab's
	// display metadata goes with it — the session it named is over.
	func drop(_ tab: VMPaneTab, vm: String) {
		if case .ssh(let ref) = tab {
			sshMeta[vm]?[ref] = nil
		}
		guard let c = live[vm]?[tab] else { return }
		c.disconnect()
		live[vm]?[tab] = nil
		appliedLive[vm]?[tab] = nil
		objectWillChange.send()
	}

	// Recreate a tab's controller with the current profile — the "Reload" action, needed
	// when a startup-only setting (scrollback/convertEol/termName/cursor/tabWidth) changed.
	// The caller re-`.id()`s the host so the new view is shown.
	public func reloadTab(
		vm: String, ref: SerialPortRef, socketPath: String?, profile: TerminalProfile
	) {
		live[vm]?[.terminal(ref)]?.disconnect()
		let c = makeController(profile)
		live[vm, default: [:]][.terminal(ref)] = c
		appliedLive[vm, default: [:]][.terminal(ref)] = profile.liveSettings
		if let path = socketPath { c.connect(path: path) }
		objectWillChange.send()
	}

	// Keeps every open terminal on its profile as the store changes, whichever window shows
	// it, or none: the registry listens itself, for the app's lifetime, never a view.
	public func follow(_ profiles: TerminalProfileStore) {
		followed = profiles
		profileWatch = profiles.objectWillChange.sink { [weak self] _ in
			self?.reapply.schedule()
		}
	}

	// Re-apply live profile settings to every open controller whose resolved profile's live
	// settings changed — an edit, a port's new profile, a deleted one. A serial tab resolves
	// through its port's association, an SSH session through its own pick (K7, T30). Covers
	// hidden VMs too, so an edit is reflected everywhere at once.
	public func reapplyLiveProfiles(_ store: TerminalProfileStore) {
		for (vm, byTab) in live {
			for (tab, c) in byTab {
				let profile: TerminalProfile
				switch tab {
				case .terminal(let ref): profile = store.profile(vm: vm, ref: ref)
				case .ssh(let ref): profile = sessionProfile(vm: vm, ref: ref, in: store)
				case .config: continue
				}
				guard appliedLive[vm]?[tab] != profile.liveSettings else { continue }
				c.applyLive(profile)
				appliedLive[vm, default: [:]][tab] = profile.liveSettings
			}
		}
	}

	// MARK: - SSH sessions (ephemeral tabs)

	// Same deferred-creation shape as the serial tabs, but the transport is a PTY-spawned
	// /usr/bin/ssh, and it is one-shot: a dead session never reconnects — open a new tab.
	// Display metadata: the ref's title is only the birth name ("Session N") — renames
	// live here so tab identity (Hashable ref) never changes; startedAt drives duration.
	private struct SSHSessionMeta {
		var name: String
		var startedAt: Date
		var profileID: UUID?   // per-session pick; nil = the default profile
	}
	private var sshMeta: [String: [SSHSessionRef: SSHSessionMeta]] = [:]

	public func sshController(vm: String, ref: SSHSessionRef) -> (any TerminalController)? {
		controller(for: .ssh(ref), vm: vm)
	}

	public func sshSessionName(vm: String, ref: SSHSessionRef) -> String {
		sshMeta[vm]?[ref]?.name ?? ref.title
	}

	public func sshSessionStart(vm: String, ref: SSHSessionRef) -> Date? {
		sshMeta[vm]?[ref]?.startedAt
	}

	// Why `draft` can't name a session, or nil: the inspector says it under the field (H64).
	public static func sshSessionNameProblem(_ draft: String) -> String? {
		draft.trimmingCharacters(in: .whitespaces).isEmpty ? "A session needs a name" : nil
	}

	// False when the name is refused (sshSessionNameProblem): the session keeps its name.
	@discardableResult
	public func renameSSHSession(vm: String, ref: SSHSessionRef, to name: String) -> Bool {
		guard Self.sshSessionNameProblem(name) == nil else { return false }
		sshMeta[vm, default: [:]][ref, default: SSHSessionMeta(
			name: ref.title, startedAt: MachmanClock.now())].name =
			name.trimmingCharacters(in: .whitespaces)
		objectWillChange.send()
		return true
	}

	public func sshSessionProfileID(vm: String, ref: SSHSessionRef) -> UUID? {
		sshMeta[vm]?[ref]?.profileID
	}

	// The profile a session uses: its own pick, else the default. A pick whose profile was
	// deleted goes, so the inspector's picker shows Default rather than nothing.
	private func sessionProfile(
		vm: String, ref: SSHSessionRef, in store: TerminalProfileStore
	) -> TerminalProfile {
		if let id = sshMeta[vm]?[ref]?.profileID {
			if let picked = store.profile(id: id) { return picked }
			sshMeta[vm]?[ref]?.profileID = nil
			objectWillChange.send()
		}
		return store.defaultProfile
	}

	// Live-apply a profile to one session (font/colors/behaviour) and remember the pick.
	// Startup-only settings can't change on a live remote session — they apply to the
	// NEXT session; there is deliberately no ssh "reload".
	public func applySSHProfile(
		vm: String, ref: SSHSessionRef, id: UUID, profile: TerminalProfile
	) {
		sshMeta[vm, default: [:]][ref, default: SSHSessionMeta(
			name: ref.title, startedAt: MachmanClock.now())].profileID = id
		if let c = live[vm]?[.ssh(ref)] {
			c.applyLive(profile)
			appliedLive[vm, default: [:]][.ssh(ref)] = profile.liveSettings
		}
		objectWillChange.send()
	}

	public func ensureSSHController(
		vm: String, ref: SSHSessionRef, arguments: [String], profile: TerminalProfile,
		stillWanted: @escaping @MainActor () -> Bool = { true }
	) {
		create(.ssh(ref), vm: vm, profile: profile, stillWanted: stillWanted) { [weak self] c in
			guard let self else { return }
			if self.sshMeta[vm]?[ref] == nil {
				self.sshMeta[vm, default: [:]][ref] =
					SSHSessionMeta(name: ref.title, startedAt: MachmanClock.now())
			}
			// TERM matches what the emulator actually is — without it ssh sends "dumb".
			c.connect(stream: PTYProcessStream(
				executablePath: "/usr/bin/ssh", arguments: arguments,
				environmentOverrides: ["TERM": profile.termName]))
		}
	}

	// Re-attach a dead session to a fresh ssh process on the SAME controller, so the tab
	// keeps its identity, its name and — the point — its scrollback. A live session is
	// left alone; the caller decides whether the guest is worth reconnecting to.
	public func reconnectSSHSession(
		vm: String, ref: SSHSessionRef, arguments: [String], profile: TerminalProfile
	) {
		guard let controller = live[vm]?[.ssh(ref)], !controller.connected else { return }
		controller.connect(stream: PTYProcessStream(
			executablePath: "/usr/bin/ssh", arguments: arguments,
			environmentOverrides: ["TERM": profile.termName]))
		noteReconnected(controller)
		objectWillChange.send()
	}

	// The session's own reconnect, from its tab's banner and its inspector alike: the VM's
	// current ssh argv and the session's own profile, else the default. False when the VM
	// can't be reached over ssh yet (no address, user or key); nothing starts then.
	@discardableResult
	public func reconnectSSHSession(
		vm: VMInfo, ref: SSHSessionRef, profiles: TerminalProfileStore
	) -> Bool {
		guard let arguments = SSHCommand.arguments(for: vm) else { return false }
		let profile = sessionProfile(vm: vm.name, ref: ref, in: profiles)
		reconnectSSHSession(vm: vm.name, ref: ref, arguments: arguments, profile: profile)
		return true
	}

	// Drop every controller (and session name) of VMs that no longer exist. Per-port
	// pruning is the canvas reconcile's job — it reports removed refs into drop.
	public func reconcile(vms: [VMInfo]) {
		forgetVMs(except: Set(vms.map(\.name)))
	}

	// The VM and tab a live controller serves: what File ▸ Save Terminal… names its file
	// after (H63). Nil for one no tab holds any more.
	public func tab(of controller: any TerminalController) -> (vm: String, tab: VMPaneTab)? {
		for (vm, tabs) in live {
			if let tab = tabs.first(where: { $0.value === controller })?.key { return (vm, tab) }
		}
		return nil
	}
}

extension TerminalSessions: VMKeyedState {
	// Migrate a VM's controllers on rename, so open terminals survive it. (A live SSH
	// process is unaffected by the rename; its argv already resolved.)
	public func renameVM(from old: String, to new: String) {
		if let c = live[old] {
			live[new] = c
			live[old] = nil
		}
		if let applied = appliedLive[old] {
			appliedLive[new] = applied
			appliedLive[old] = nil
		}
		if let m = sshMeta[old] {
			sshMeta[new] = m
			sshMeta[old] = nil
		}
	}

	// The terminals are the run's: Save as New VM takes them to the saved VM.
	public func copyVM(from old: String, to new: String) {
		renameVM(from: old, to: new)
	}

	// `kept` are the VMs whose controllers stay.
	public func forgetVMs(except kept: Set<String>) {
		for vm in Array(live.keys) where !kept.contains(vm) {
			live[vm]?.values.forEach { $0.disconnect() }
			live[vm] = nil
			appliedLive[vm] = nil
		}
		for vm in Array(sshMeta.keys) where !kept.contains(vm) {
			sshMeta[vm] = nil
		}
	}
}
