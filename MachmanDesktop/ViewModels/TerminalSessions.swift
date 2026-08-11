//
//  TerminalSessions.swift
//  MachmanDesktop
//
//  The per-VM terminal-tab registry: which ports are open as tabs (VMTabState) and the live
//  SerialTerminalController behind each. Held by VMListViewModel so terminals persist across VM
//  navigation and while their tab is hidden — a connection lives exactly as long as its tab is
//  open, torn down only on explicit close, port removal, or VM deletion. The pure tab
//  ordering/activation logic lives in MachmanUI's VMTabState; this adds the SwiftTerm lifecycle.
//

import Foundation
import MachmanAPI
import MachmanUI

@MainActor
final class TerminalSessions: ObservableObject {
	// Per-VM open-tab layout (published so the tab strip / container re-render on change).
	@Published private var states: [String: VMTabState] = [:]
	// Per-VM live controllers, keyed by port ref. Not published: views observe `states` for
	// structure and each controller's own @Published `connected` for status.
	private var controllers: [String: [SerialPortRef: SerialTerminalController]] = [:]

	// MARK: - Reads

	func state(_ vm: String) -> VMTabState { states[vm] ?? VMTabState() }

	func isOpen(vm: String, ref: SerialPortRef) -> Bool {
		state(vm).openPorts.contains(ref)
	}

	func controller(vm: String, ref: SerialPortRef) -> SerialTerminalController? {
		controllers[vm]?[ref]
	}

	// The controller for the VM's active tab (nil on the config tab) — drives File → Save Terminal.
	func activeController(vm: String) -> SerialTerminalController? {
		guard case let .terminal(ref) = state(vm).active else { return nil }
		return controller(vm: vm, ref: ref)
	}

	// MARK: - Tab lifecycle

	// Open (or focus) a port's tab. Creates + connects a controller the first time; re-opening an
	// already-open port just re-focuses it (and reconnects if its socket has come back).
	func openTab(
		vm: String, ref: SerialPortRef, socketPath: String?, profile: TerminalProfile
	) {
		if controllers[vm]?[ref] == nil {
			controllers[vm, default: [:]][ref] = SerialTerminalController(profile: profile)
		}
		if let path = socketPath { controllers[vm]?[ref]?.connect(path: path) }
		var s = state(vm)
		s.open(ref)
		states[vm] = s
	}

	func setActive(_ tab: VMPaneTab, for vm: String) {
		var s = state(vm)
		s.activate(tab)
		states[vm] = s
	}

	// Close a tab: disconnect + drop its controller, and let the tab state pick the next active.
	func closeTab(vm: String, ref: SerialPortRef) {
		controllers[vm]?[ref]?.disconnect()
		controllers[vm]?[ref] = nil
		var s = state(vm)
		s.close(ref)
		states[vm] = s
	}

	// Recreate a tab's controller with the current profile — the "Reload" action, needed when a
	// startup-only setting (scrollback/convertEol/termName/cursor/tabWidth) changed. Keeps the tab
	// open and active; the caller re-`.id()`s the host so the new view is shown.
	func reloadTab(
		vm: String, ref: SerialPortRef, socketPath: String?, profile: TerminalProfile
	) {
		guard isOpen(vm: vm, ref: ref) else { return }
		controllers[vm]?[ref]?.disconnect()
		let c = SerialTerminalController(profile: profile)
		controllers[vm, default: [:]][ref] = c
		if let path = socketPath { c.connect(path: path) }
	}

	// Re-attach an open-but-disconnected tab when its socket reappears (VM restart; the socket
	// path hash is stable across restarts, so connect() is idempotent per path).
	func reconnectIfPossible(vm: String, ref: SerialPortRef, socketPath: String?) {
		guard let path = socketPath, let c = controllers[vm]?[ref], !c.connected else { return }
		c.connect(path: path)
	}

	// MARK: - Cross-cutting updates

	// Re-apply live profile settings to every open controller (called when a profile is edited).
	// Covers hidden VMs too, so an edit is reflected everywhere at once.
	func reapplyLiveProfiles(_ store: TerminalProfileStore) {
		for (vm, byRef) in controllers {
			for (ref, c) in byRef {
				c.applyLive(store.profile(vm: vm, ref: ref))
			}
		}
	}

	// Close tabs whose port no longer exists, and drop VMs that are gone entirely.
	func reconcile(vms: [VMInfo]) {
		let byName = Dictionary(vms.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
		// VMs that vanished: disconnect everything, drop wholesale. Snapshot keys — we mutate.
		for vm in Array(states.keys) where byName[vm] == nil {
			controllers[vm]?.values.forEach { $0.disconnect() }
			controllers[vm] = nil
			states[vm] = nil
		}
		// Surviving VMs: drop tabs for ports that no longer exist.
		for (vm, info) in byName {
			guard var s = states[vm] else { continue }
			let removed = s.reconcile(existing: Set(refs(of: info)))
			guard !removed.isEmpty else { continue }
			for ref in removed {
				controllers[vm]?[ref]?.disconnect()
				controllers[vm]?[ref] = nil
			}
			states[vm] = s
		}
	}

	// Migrate a VM's tabs + controllers on rename, so open terminals survive it.
	func renameVM(from old: String, to new: String) {
		if let s = states[old] { states[new] = s; states[old] = nil }
		if let c = controllers[old] { controllers[new] = c; controllers[old] = nil }
	}

	private func refs(of info: VMInfo) -> [SerialPortRef] {
		(info.consolePorts ?? []).map { SerialPortRef($0) }
			+ (info.uartPorts ?? []).map { SerialPortRef($0) }
	}
}
