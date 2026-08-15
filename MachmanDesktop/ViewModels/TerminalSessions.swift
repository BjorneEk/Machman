//
//  TerminalSessions.swift
//  MachmanDesktop
//
//  The live SwiftTerm controllers behind terminal tabs, keyed (vm, port). Pure controller
//  lifecycle — WHICH tabs exist and which is active lives in CanvasStateStore (the canvas
//  layout); this registry only creates, connects, reloads, and tears down terminals on
//  demand. App-scoped, so controllers (and their transcripts) survive VM navigation and
//  daemon reconnects; a controller lives exactly as long as its tab is open.
//

import Foundation
import MachmanAPI
import MachmanUI

@MainActor
final class TerminalSessions: ObservableObject {
	// Not published per-keystroke: views observe each controller's own @Published
	// `connected`; objectWillChange fires when a controller appears or disappears.
	private var controllers: [String: [SerialPortRef: SerialTerminalController]] = [:]
	// Tabs whose controller is being created on a deferred runloop turn (so the spinner
	// shows and we don't schedule creation twice).
	private var creating: Set<String> = []

	func controller(vm: String, ref: SerialPortRef) -> SerialTerminalController? {
		controllers[vm]?[ref]
	}

	// Make sure the tab's controller exists and is connected, ready to render. The
	// TerminalView is built on a later runloop turn so the tab + spinner paint first
	// (AppKit view creation is main-thread-bound — deferral, not backgrounding, but the
	// click stays instant). `stillWanted` re-checks on that turn: the tab may have closed.
	// Idempotent per tab; also (re)connects an existing controller whose socket reappeared.
	func ensureController(
		vm: String, ref: SerialPortRef, socketPath: String?, profile: TerminalProfile,
		stillWanted: @escaping @MainActor () -> Bool = { true }
	) {
		if let c = controllers[vm]?[ref] {
			if let path = socketPath, !c.connected { c.connect(path: path) }
			return
		}
		let key = ref.assocKey(vm: vm)
		guard !creating.contains(key) else { return }
		creating.insert(key)
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			self.creating.remove(key)
			guard stillWanted() else { return }
			let c = SerialTerminalController(profile: profile)
			self.controllers[vm, default: [:]][ref] = c
			if let path = socketPath { c.connect(path: path) }
			self.objectWillChange.send()   // swap the spinner for the terminal
		}
	}

	// Tear down a tab's controller: tab closed, port removed, or VM deleted.
	func dropController(vm: String, ref: SerialPortRef) {
		guard let c = controllers[vm]?[ref] else { return }
		c.disconnect()
		controllers[vm]?[ref] = nil
		objectWillChange.send()
	}

	// Recreate a tab's controller with the current profile — the "Reload" action, needed
	// when a startup-only setting (scrollback/convertEol/termName/cursor/tabWidth) changed.
	// The caller re-`.id()`s the host so the new view is shown.
	func reloadTab(
		vm: String, ref: SerialPortRef, socketPath: String?, profile: TerminalProfile
	) {
		controllers[vm]?[ref]?.disconnect()
		let c = SerialTerminalController(profile: profile)
		controllers[vm, default: [:]][ref] = c
		if let path = socketPath { c.connect(path: path) }
		objectWillChange.send()
	}

	// Re-apply live profile settings to every open controller (profile edited). Covers
	// hidden VMs too, so an edit is reflected everywhere at once.
	func reapplyLiveProfiles(_ store: TerminalProfileStore) {
		for (vm, byRef) in controllers {
			for (ref, c) in byRef {
				c.applyLive(store.profile(vm: vm, ref: ref))
			}
		}
	}

	// MARK: - SSH sessions (ephemeral tabs)

	// Same deferred-creation shape as the serial tabs, but the transport is a PTY-spawned
	// /usr/bin/ssh, and it is one-shot: a dead session never reconnects — open a new tab.
	private var sshControllers: [String: [SSHSessionRef: SerialTerminalController]] = [:]

	func sshController(vm: String, ref: SSHSessionRef) -> SerialTerminalController? {
		sshControllers[vm]?[ref]
	}

	func ensureSSHController(
		vm: String, ref: SSHSessionRef, arguments: [String], profile: TerminalProfile,
		stillWanted: @escaping @MainActor () -> Bool = { true }
	) {
		guard sshControllers[vm]?[ref] == nil else { return }
		let key = "ssh|\(vm)|\(ref.id.uuidString)"
		guard !creating.contains(key) else { return }
		creating.insert(key)
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			self.creating.remove(key)
			guard stillWanted() else { return }
			let c = SerialTerminalController(profile: profile)
			self.sshControllers[vm, default: [:]][ref] = c
			// TERM matches what the emulator actually is — without it ssh sends "dumb".
			c.connect(stream: PTYProcessStream(
				executablePath: "/usr/bin/ssh", arguments: arguments,
				environmentOverrides: ["TERM": profile.termName]))
			self.objectWillChange.send()
		}
	}

	func dropSSHController(vm: String, ref: SSHSessionRef) {
		guard let c = sshControllers[vm]?[ref] else { return }
		c.disconnect()
		sshControllers[vm]?[ref] = nil
		objectWillChange.send()
	}

	// Drop every controller of VMs that no longer exist. Per-port pruning is the canvas
	// reconcile's job — it reports removed refs into dropController.
	func reconcile(vms: [VMInfo]) {
		let names = Set(vms.map(\.name))
		for vm in Array(controllers.keys) where !names.contains(vm) {
			controllers[vm]?.values.forEach { $0.disconnect() }
			controllers[vm] = nil
		}
		for vm in Array(sshControllers.keys) where !names.contains(vm) {
			sshControllers[vm]?.values.forEach { $0.disconnect() }
			sshControllers[vm] = nil
		}
	}

	// Migrate a VM's controllers on rename, so open terminals survive it. (A live SSH
	// process is unaffected by the rename; its argv already resolved.)
	func renameVM(from old: String, to new: String) {
		if let c = controllers[old] {
			controllers[new] = c
			controllers[old] = nil
		}
		if let c = sshControllers[old] {
			sshControllers[new] = c
			sshControllers[old] = nil
		}
	}
}
