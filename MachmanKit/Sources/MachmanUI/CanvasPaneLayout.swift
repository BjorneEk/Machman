//
//  CanvasPaneLayout.swift
//  MachmanUI
//
//  How wide each canvas pane is drawn (L2). The persisted fractions say how the canvas is
//  shared; this turns them into widths that always fit: the panes plus their dividers sum to
//  exactly the canvas width, every pane gets at least the minimum when there is room for it,
//  and an over-narrow canvas splits evenly instead of pushing the trailing pane (and its tab
//  strip) off the window. Corrupt fractions (from a hand-edited layouts file) fit too; the
//  stored values are never rewritten here.
//

import CoreGraphics

public enum CanvasPaneLayout {
	public static let minimumPaneWidth: CGFloat = 120

	public static func widths(
		fractions: [Double], total: CGFloat, divider: CGFloat,
		minimum: CGFloat = minimumPaneWidth
	) -> [CGFloat] {
		let n = fractions.count
		guard n > 0 else { return [] }
		let available = max(0, total - divider * CGFloat(n - 1))
		var shares = fractions.map { $0.isFinite && $0 > 0 ? CGFloat($0) : 0 }
		if shares.allSatisfy({ $0 == 0 }) { shares = Array(repeating: 1, count: n) }
		let floor = min(minimum, available / CGFloat(n))
		// Water-fill: share the room among the unpinned panes; any pane that comes out
		// under the floor is pinned at it and the rest share again, until nothing changes.
		var pinned = Array(repeating: false, count: n)
		var widths = Array(repeating: floor, count: n)
		while true {
			let free = pinned.indices.filter { !pinned[$0] }
			let room = available - floor * CGFloat(n - free.count)
			let shareSum = free.reduce(CGFloat(0)) { $0 + shares[$1] }
			var pinnedOne = false
			for i in free {
				let width = shareSum > 0
					? room * shares[i] / shareSum : room / CGFloat(free.count)
				widths[i] = width
				if width < floor {
					pinned[i] = true
					widths[i] = floor
					pinnedOne = true
				}
			}
			if !pinnedOne { return widths }
		}
	}
}
