//
//  CanvasTabDrag.swift
//  MachmanUI
//
//  The canvas's in-flight tab drag as a value (1.0.4 UI, demo parity), apart from the views
//  so its rules are unit-testable. A drag reorders live within its strip until it detaches —
//  pulled down, or off its strip — and a detached drag's release tears the tab off (outside
//  the canvas), inserts it into the strip under the cursor, moves it to another pane or splits
//  a new edge pane, by drop zones computed from the frames the views measured. VMCanvasView
//  applies the results to the CanvasState and draws the zones and the ghost.
//

import Foundation
import CoreGraphics

public struct CanvasTabDrag: Equatable, Sendable {
	// Measured geometry, in canvas space, as the views report it.
	public struct Frames: Equatable, Sendable {
		public var canvasSize: CGSize
		public var panes: [UUID: CGRect]
		public var strips: [UUID: CGRect]
		public var tabs: [VMPaneTab: CGRect]

		public init(
			canvasSize: CGSize = .zero, panes: [UUID: CGRect] = [:],
			strips: [UUID: CGRect] = [:], tabs: [VMPaneTab: CGRect] = [:]
		) {
			self.canvasSize = canvasSize
			self.panes = panes
			self.strips = strips
			self.tabs = tabs
		}
	}

	public enum Zone: Equatable, Sendable {
		case pane(UUID)
		case newLeading
		case newTrailing
	}

	// A drop zone and its rect in canvas space.
	public struct Target: Equatable, Sendable {
		public let zone: Zone
		public let rect: CGRect

		public init(zone: Zone, rect: CGRect) {
			self.zone = zone
			self.rect = rect
		}
	}

	// What releasing the drag does to the canvas.
	public enum Release: Equatable, Sendable {
		case stay
		case tearOff
		case move(toPane: UUID, at: Int)
		case split(trailing: Bool)
	}

	public let tab: VMPaneTab
	public let paneID: UUID
	public private(set) var location: CGPoint
	public private(set) var translation: CGSize
	public private(set) var detached = false
	// Widths of siblings crossed during live reorder, so the tab stays under the cursor.
	public private(set) var baselineShift: CGFloat = 0

	public init(tab: VMPaneTab, paneID: UUID, location: CGPoint, translation: CGSize) {
		self.tab = tab
		self.paneID = paneID
		self.location = location
		self.translation = translation
	}

	// One gesture sample. Ghost mode when pulled down OR whenever the cursor leaves the source
	// strip — the strips are clipping ScrollViews, so only the top-level ghost can cross
	// panes. Returns the index a live reorder moves the tab to (the caller applies it to the
	// canvas), nil when the tab stays where it is.
	public mutating func update(
		location: CGPoint, translation: CGSize, canvas: CanvasState, frames: Frames
	) -> Int? {
		self.location = location
		self.translation = translation
		let inSourceStrip = frames.strips[paneID]?
			.insetBy(dx: -8, dy: -8).contains(location) ?? true
		detached = abs(translation.height) > 42 || !inSourceStrip
		return detached ? nil : reorderTarget(canvas: canvas, frames: frames)
	}

	// Live reorder: when the cursor passes a sibling tab's midpoint, move the tab and add the
	// sibling's width to the baseline so the dragged tab stays under the cursor.
	private mutating func reorderTarget(canvas: CanvasState, frames: Frames) -> Int? {
		guard let holder = canvas.pane(holding: tab),
			let pane = canvas.panes.first(where: { $0.id == holder }),
			let ti = pane.tabs.firstIndex(of: tab) else { return nil }
		let x = location.x
		if ti + 1 < pane.tabs.count,
			let next = frames.tabs[pane.tabs[ti + 1]], x > next.midX + 2 {
			baselineShift += next.width
			return ti + 1
		}
		if ti > 0, let prev = frames.tabs[pane.tabs[ti - 1]], x < prev.midX - 2 {
			baselineShift -= prev.width
			return ti - 1
		}
		return nil
	}

	// Whether going from `old` to `new` switches the ghost and drop zones on or off: the one
	// change worth animating (H50). A drag that starts detached counts as switching on.
	public static func detachChanges(from old: CanvasTabDrag?, to new: CanvasTabDrag) -> Bool {
		(old?.detached ?? false) != new.detached
	}

	// Where `tab` draws in its strip while the drag is attached: under the cursor, less the
	// siblings it crossed, lifted a little. Other tabs, and a detached drag (the ghost has
	// it), stay put.
	public func offset(for tab: VMPaneTab) -> CGSize {
		guard tab == self.tab, !detached else { return .zero }
		return CGSize(
			width: translation.width - baselineShift,
			height: max(-4, min(4, translation.height * 0.2)))
	}

	public func release(canvas: CanvasState, frames: Frames) -> Release {
		guard detached else { return .stay }
		// Released outside the canvas (with margin) → tear off into its own window.
		let canvasRect = CGRect(origin: .zero, size: frames.canvasSize)
			.insetBy(dx: -40, dy: -40)
		if !canvasRect.contains(location) { return .tearOff }
		// Released over a strip → insert at that position.
		if let (pane, index) = Self.stripInsertion(
			at: location, excluding: tab, canvas: canvas, frames: frames) {
			return .move(toPane: pane, at: index)
		}
		switch Self.zone(at: location, canvas: canvas, frames: frames) {
		case .pane(let id):
			guard id != paneID else { return .stay }
			let count = canvas.panes.first { $0.id == id }?.tabs
				.filter { $0 != tab }.count ?? 0
			return .move(toPane: id, at: count)
		case .newLeading:
			return .split(trailing: false)
		case .newTrailing:
			return .split(trailing: true)
		case nil:
			return .stay
		}
	}

	// Which strip is under the cursor, and the insertion index among its tabs (computed
	// EXCLUDING the dragged tab, so it stays valid after removal).
	private static func stripInsertion(
		at loc: CGPoint, excluding dragged: VMPaneTab, canvas: CanvasState, frames: Frames
	) -> (UUID, Int)? {
		for pane in canvas.panes {
			guard let strip = frames.strips[pane.id],
				strip.insetBy(dx: 0, dy: -6).contains(loc) else { continue }
			let index = pane.tabs
				.filter { $0 != dragged }
				.filter { tab in
					guard let frame = frames.tabs[tab] else { return false }
					return frame.midX < loc.x
				}
				.count
			return (pane.id, index)
		}
		return nil
	}

	// Zone rects in canvas space, from MEASURED pane frames (immune to sidebar/inspector
	// state); edge split-zones first, they win overlaps.
	public static func dropZones(canvas: CanvasState, frames: Frames) -> [Target] {
		let size = frames.canvasSize
		guard size.width > 0 else { return [] }
		var zones: [Target] = []
		let edge = max(56, size.width * 0.11)
		if canvas.panes.count < CanvasState.maxPanes {
			zones.append(Target(zone: .newLeading,
				rect: CGRect(x: 4, y: 4, width: edge, height: size.height - 8)))
			zones.append(Target(zone: .newTrailing,
				rect: CGRect(x: size.width - edge - 4, y: 4, width: edge, height: size.height - 8)))
		}
		for (i, pane) in canvas.panes.enumerated() {
			guard let measured = frames.panes[pane.id] else { continue }
			let edgePane = i == 0 || i == canvas.panes.count - 1
			let inset: CGFloat = canvas.panes.count < CanvasState.maxPanes && edgePane
				? (edge + 10) * 0.5 : 12
			zones.append(Target(zone: .pane(pane.id), rect: measured.insetBy(dx: inset, dy: 24)))
		}
		return zones
	}

	public static func zone(at location: CGPoint, canvas: CanvasState, frames: Frames) -> Zone? {
		dropZones(canvas: canvas, frames: frames).first { $0.rect.contains(location) }?.zone
	}
}
