//
//  CanvasState.swift
//  MachmanUI
//
//  The pure editor-canvas layout for one VM (1.0.4 UI): panes of ordered tabs, an active
//  pane, and divider fractions. Generalizes VMTabState from one implicit pane to the
//  overhaul's split canvas; same philosophy — value-only, SwiftTerm-free, unit-testable,
//  and Codable so each VM's canvas persists and is restored as it last appeared. The live
//  controllers the terminal tabs point at stay in the app target (TerminalSessions).
//

import Foundation

// Stable coding for persistence: {"kind":"config"} / {"kind":"terminal","port":{…}} —
// never the synthesized positional shape.
extension VMPaneTab: Codable {
	private enum CodingKeys: String, CodingKey {
		case kind
		case port
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		switch try c.decode(String.self, forKey: .kind) {
		case "terminal":
			self = .terminal(try c.decode(SerialPortRef.self, forKey: .port))
		default:
			self = .config
		}
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .config:
			try c.encode("config", forKey: .kind)
		case .terminal(let ref):
			try c.encode("terminal", forKey: .kind)
			try c.encode(ref, forKey: .port)
		}
	}
}

public struct CanvasPane: Equatable, Sendable, Codable, Identifiable {
	public let id: UUID
	public private(set) var tabs: [VMPaneTab]
	public private(set) var active: VMPaneTab?

	public init(id: UUID = UUID(), tabs: [VMPaneTab] = [], active: VMPaneTab? = nil) {
		self.id = id
		self.tabs = tabs
		self.active = active ?? tabs.first
	}

	// VMTabState's activation rules, per pane: only open tabs can be active.
	mutating func activate(_ tab: VMPaneTab) {
		guard tabs.contains(tab) else { return }
		active = tab
	}

	// Idempotent open-or-focus at an optional position.
	mutating func open(_ tab: VMPaneTab, at index: Int? = nil) {
		if !tabs.contains(tab) {
			let insertAt = min(max(0, index ?? tabs.count), tabs.count)
			tabs.insert(tab, at: insertAt)
		}
		active = tab
	}

	// VMTabState's close fallback: the right neighbour slides in, else the left, else nil.
	mutating func close(_ tab: VMPaneTab) {
		guard let i = tabs.firstIndex(of: tab) else { return }
		let wasActive = active == tab
		tabs.remove(at: i)
		if wasActive {
			active = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)]
		}
	}

	mutating func remove(where predicate: (VMPaneTab) -> Bool) {
		tabs.removeAll(where: predicate)
		if let current = active, predicate(current) {
			active = tabs.last
		}
	}

	// Reposition without touching activation (live drag reorder).
	mutating func move(from: Int, to: Int) {
		guard tabs.indices.contains(from), tabs.indices.contains(to) else { return }
		tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
	}
}

public struct CanvasState: Equatable, Sendable, Codable {
	public static let maxPanes = 3

	public private(set) var panes: [CanvasPane]
	public private(set) var activePaneID: UUID?
	public private(set) var fractions: [Double]

	public init() {
		let pane = CanvasPane()
		panes = [pane]
		activePaneID = pane.id
		fractions = [1.0]
	}

	public init(panes: [CanvasPane], activePaneID: UUID? = nil, fractions: [Double]? = nil) {
		self.panes = panes.isEmpty ? [CanvasPane()] : panes
		self.activePaneID = activePaneID ?? self.panes.first?.id
		self.fractions = fractions ?? []
		normalize()
	}

	public var activePane: CanvasPane? {
		panes.first { $0.id == activePaneID } ?? panes.first
	}

	public var activeTab: VMPaneTab? { activePane?.active }

	public var allOpenTabs: [VMPaneTab] { panes.flatMap(\.tabs) }

	// Which pane holds a tab (a tab lives in at most one pane).
	public func pane(holding tab: VMPaneTab) -> UUID? {
		panes.first { $0.tabs.contains(tab) }?.id
	}

	// MARK: - Mutations

	// Open-or-focus: an already-open tab focuses wherever it lives; a new one joins the
	// active pane. Clicking twice never duplicates.
	public mutating func open(_ tab: VMPaneTab) {
		if let holder = pane(holding: tab), let i = index(of: holder) {
			panes[i].activate(tab)
			activePaneID = holder
			return
		}
		let target = index(of: activePaneID) ?? 0
		panes[target].open(tab)
		activePaneID = panes[target].id
	}

	public mutating func activate(_ tab: VMPaneTab) {
		guard let holder = pane(holding: tab), let i = index(of: holder) else { return }
		panes[i].activate(tab)
		activePaneID = holder
	}

	public mutating func activatePane(_ id: UUID) {
		guard panes.contains(where: { $0.id == id }) else { return }
		activePaneID = id
	}

	// Close a tab; a pane emptied by it collapses (unless it is the last pane).
	public mutating func close(_ tab: VMPaneTab) {
		guard let holder = pane(holding: tab), let i = index(of: holder) else { return }
		panes[i].close(tab)
		collapseEmptyPanes()
	}

	// Move a tab into a pane at an index computed EXCLUDING the moved tab (drag semantics:
	// it stays valid after removal). Same-pane moves reposition.
	public mutating func move(_ tab: VMPaneTab, toPane target: UUID, at index: Int? = nil) {
		guard let from = pane(holding: tab), let fromIdx = self.index(of: from),
			let targetIdx = self.index(of: target) else { return }
		if from == target && index == nil { return }
		panes[fromIdx].close(tab)
		panes[targetIdx].open(tab, at: index)
		activePaneID = target
		collapseEmptyPanes()
	}

	// Live-reorder a tab within its pane WITHOUT changing activation (drag semantics: the
	// index is the tab's final position among the pane's tabs).
	public mutating func reorder(_ tab: VMPaneTab, to index: Int) {
		guard let holder = pane(holding: tab), let pi = self.index(of: holder),
			let from = panes[pi].tabs.firstIndex(of: tab) else { return }
		let clamped = min(max(0, index), panes[pi].tabs.count - 1)
		guard clamped != from else { return }
		panes[pi].move(from: from, to: clamped)
	}

	// Split: the tab moves into a NEW pane at the leading/trailing edge (≤ maxPanes).
	public mutating func split(_ tab: VMPaneTab, trailing: Bool = true) {
		guard panes.count < Self.maxPanes,
			let from = pane(holding: tab), let fromIdx = index(of: from) else { return }
		panes[fromIdx].close(tab)
		let pane = CanvasPane(tabs: [tab])
		if trailing { panes.append(pane) } else { panes.insert(pane, at: 0) }
		activePaneID = pane.id
		collapseEmptyPanes()
		resetFractions()
	}

	public mutating func setFraction(_ value: Double, at index: Int) {
		guard fractions.indices.contains(index), fractions.indices.contains(index + 1)
			else { return }
		let pair = fractions[index] + fractions[index + 1]
		let clamped = min(max(0.15, value), pair - 0.15)
		fractions[index] = clamped
		fractions[index + 1] = pair - clamped
	}

	// Drop terminal tabs whose port no longer exists (VMTabState.reconcile, across panes);
	// returns the closed refs so the caller tears down their controllers.
	@discardableResult
	public mutating func reconcile(existing: Set<SerialPortRef>) -> [SerialPortRef] {
		var removed: [SerialPortRef] = []
		for i in panes.indices {
			for tab in panes[i].tabs {
				if case .terminal(let ref) = tab, !existing.contains(ref) {
					removed.append(ref)
				}
			}
			panes[i].remove { tab in
				if case .terminal(let ref) = tab { return !existing.contains(ref) }
				return false
			}
		}
		if !removed.isEmpty { collapseEmptyPanes() }
		return removed
	}

	// MARK: - Internals

	private func index(of id: UUID?) -> Int? {
		guard let id else { return nil }
		return panes.firstIndex { $0.id == id }
	}

	private mutating func collapseEmptyPanes() {
		if panes.count > 1 {
			panes.removeAll { $0.tabs.isEmpty }
			if panes.isEmpty { panes = [CanvasPane()] }
		}
		if index(of: activePaneID) == nil {
			activePaneID = panes.first?.id
		}
		normalize()
	}

	private mutating func resetFractions() {
		fractions = Array(repeating: 1.0 / Double(panes.count), count: panes.count)
	}

	private mutating func normalize() {
		if fractions.count != panes.count {
			resetFractions()
		}
	}
}
