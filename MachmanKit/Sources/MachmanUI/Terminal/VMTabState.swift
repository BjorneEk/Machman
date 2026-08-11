//
//  VMTabState.swift
//  MachmanUI
//
//  The pure tab-layout state for one VM's detail pane: which terminal ports are open (as ordered
//  tabs) and which tab is active. Deliberately value-only and SwiftTerm-free so the ordering /
//  activation / reconciliation rules are unit-testable; the live SerialTerminalController registry
//  these tabs point at lives in the app target (TerminalSessions).
//

import Foundation

// Which tab is active in a VM's pane. The config tab (gear) is always present and is the fallback
// when no terminal tab is; terminal tabs are keyed by their stable port ref.
public enum VMPaneTab: Hashable, Sendable {
	case config
	case terminal(SerialPortRef)
}

public struct VMTabState: Equatable, Sendable {
	// Open terminal tabs, left-to-right. The config tab is implicit (always first, never here).
	public private(set) var openPorts: [SerialPortRef]
	public private(set) var active: VMPaneTab

	public init(openPorts: [SerialPortRef] = [], active: VMPaneTab = .config) {
		self.openPorts = openPorts
		self.active = active
	}

	// Open a port's tab (idempotent) and make it active. Re-opening an already-open port just
	// focuses it, so clicking a port twice never duplicates a tab.
	public mutating func open(_ ref: SerialPortRef) {
		if !openPorts.contains(ref) {
			openPorts.append(ref)
		}
		active = .terminal(ref)
	}

	// Select a tab. A terminal tab that isn't open is ignored (the config tab is always valid).
	public mutating func activate(_ tab: VMPaneTab) {
		if case let .terminal(ref) = tab, !openPorts.contains(ref) { return }
		active = tab
	}

	// Close a port's tab. If it was active, fall back to the tab that slides into its slot (the
	// right neighbour), or the left one when closing the last tab, or the config tab when none
	// remain.
	public mutating func close(_ ref: SerialPortRef) {
		guard let i = openPorts.firstIndex(of: ref) else { return }
		let wasActive = active == .terminal(ref)
		openPorts.remove(at: i)
		if wasActive {
			active = openPorts.isEmpty ? .config
				: .terminal(openPorts[min(i, openPorts.count - 1)])
		}
	}

	// Drop tabs whose port no longer exists on the VM (count reduced / reconfigured), keeping
	// order; fix the active tab if it vanished. Returns the closed refs so the caller can tear
	// down their controllers.
	@discardableResult
	public mutating func reconcile(existing: Set<SerialPortRef>) -> [SerialPortRef] {
		let removed = openPorts.filter { !existing.contains($0) }
		guard !removed.isEmpty else { return [] }
		openPorts.removeAll { !existing.contains($0) }
		if case let .terminal(ref) = active, !existing.contains(ref) {
			active = openPorts.last.map { .terminal($0) } ?? .config
		}
		return removed
	}
}
