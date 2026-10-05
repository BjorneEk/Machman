//
//  CanvasDividerDrag.swift
//  MachmanUI
//
//  A pane-divider drag as a value (P9): the fractions the canvas shows while the divider
//  moves, worked out from the layout the drag started on. The canvas keeps it in its own view
//  state and stores the result once, on release; every drag event used to write
//  CanvasStateStore, re-rendering the window, the menus and every torn window per frame.
//

import Foundation
import CoreGraphics

public struct CanvasDividerDrag: Equatable, Sendable {
	public let index: Int
	private let base: CanvasState
	public private(set) var fractions: [Double]

	// `index` is the divider's: it sits between pane `index` and pane `index + 1`.
	public init(index: Int, canvas: CanvasState) {
		self.index = index
		base = canvas
		fractions = canvas.fractions
	}

	// One sample: the divider moved `translation` points across `available` points of panes
	// since the drag began, clamped as CanvasState.setFraction clamps.
	public mutating func update(translation: CGFloat, available: CGFloat) {
		guard base.fractions.indices.contains(index) else { return }
		var canvas = base
		canvas.setFraction(
			base.fractions[index] + Double(translation / max(available, 1)), at: index)
		fractions = canvas.fractions
	}

	// The layout to store on release: `canvas` with the dragged divider where it ended.
	public func committed(to canvas: CanvasState) -> CanvasState {
		var result = canvas
		if fractions.indices.contains(index) {
			result.setFraction(fractions[index], at: index)
		}
		return result
	}
}
