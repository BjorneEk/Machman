import Testing
import Foundation
import CoreGraphics
import MachmanAPI
import MachmanUI

// The canvas tab drag's rules (Q11: moved out of VMCanvasView unchanged), pinned at today's
// numbers: live reorder past a sibling's midpoint ± 2 pt, detach past 42 pt down or off the
// strip's 8 pt margin, the release's tear-off / strip insert / move / split, and the drop
// zones built from measured frames.
struct CanvasTabDragTests {
	private let hvc0 = VMPaneTab.terminal(SerialPortRef(kind: .console, index: 0))
	private let hvc1 = VMPaneTab.terminal(SerialPortRef(kind: .console, index: 1))
	private let left = UUID()
	private let right = UUID()
	private let third = UUID()

	private func tab(at x: CGFloat) -> CGRect { CGRect(x: x, y: 0, width: 100, height: 30) }

	private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

	// One pane of config, hvc0, hvc1: 100 pt tabs along the 30 pt strip of a 1000×600 canvas.
	private func onePane() -> (CanvasState, CanvasTabDrag.Frames) {
		let canvas = CanvasState(panes: [CanvasPane(id: left, tabs: [.config, hvc0, hvc1])])
		let frames = CanvasTabDrag.Frames(
			canvasSize: CGSize(width: 1000, height: 600),
			panes: [left: CGRect(x: 0, y: 0, width: 1000, height: 600)],
			strips: [left: CGRect(x: 0, y: 0, width: 1000, height: 30)],
			tabs: [.config: tab(at: 0), hvc0: tab(at: 100), hvc1: tab(at: 200)])
		return (canvas, frames)
	}

	// Two panes split at 495 | 505: config and hvc0 on the left, hvc1 on the right.
	private func twoPanes() -> (CanvasState, CanvasTabDrag.Frames) {
		let canvas = CanvasState(panes: [
			CanvasPane(id: left, tabs: [.config, hvc0]), CanvasPane(id: right, tabs: [hvc1]),
		])
		let frames = CanvasTabDrag.Frames(
			canvasSize: CGSize(width: 1000, height: 600),
			panes: [
				left: CGRect(x: 0, y: 0, width: 495, height: 600),
				right: CGRect(x: 505, y: 0, width: 495, height: 600),
			],
			strips: [
				left: CGRect(x: 0, y: 0, width: 495, height: 30),
				right: CGRect(x: 505, y: 0, width: 495, height: 30),
			],
			tabs: [.config: tab(at: 0), hvc0: tab(at: 100), hvc1: tab(at: 505)])
		return (canvas, frames)
	}

	// hvc0 picked up at (150, 15) and pulled to `location`, which detaches it off its strip.
	private func detachedDrag(
		to location: CGPoint, _ canvas: CanvasState, _ frames: CanvasTabDrag.Frames
	) -> CanvasTabDrag {
		var drag = CanvasTabDrag(
			tab: hvc0, paneID: left, location: point(150, 15), translation: .zero)
		let moved = CGSize(width: location.x - 150, height: location.y - 15)
		_ = drag.update(location: location, translation: moved, canvas: canvas, frames: frames)
		return drag
	}

	private func close(_ a: CGRect, _ b: CGRect) -> Bool {
		abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001
			&& abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
	}

	// MARK: - Live reorder

	@Test func reorderWaitsForTheNextTabsMidpointPlusTwo() {
		let (canvas, frames) = onePane()
		var drag = CanvasTabDrag(
			tab: .config, paneID: left, location: point(50, 15), translation: .zero)
		#expect(drag.update(
			location: point(152, 15), translation: CGSize(width: 102, height: 0),
			canvas: canvas, frames: frames) == nil)
		#expect(drag.update(
			location: point(153, 15), translation: CGSize(width: 103, height: 0),
			canvas: canvas, frames: frames) == 1)
		#expect(drag.baselineShift == 100)
		#expect(!drag.detached)
		// The tab stays under the cursor: the crossed sibling's width comes off the offset.
		#expect(drag.offset(for: .config) == CGSize(width: 3, height: 0))
	}

	@Test func reorderBackWaitsForThePreviousTabsMidpointMinusTwo() {
		var (canvas, frames) = onePane()
		var drag = CanvasTabDrag(
			tab: .config, paneID: left, location: point(50, 15), translation: .zero)
		#expect(drag.update(
			location: point(153, 15), translation: CGSize(width: 103, height: 0),
			canvas: canvas, frames: frames) == 1)
		// The caller applies the reorder; the views measure the new positions.
		canvas.reorder(.config, to: 1)
		frames.tabs[.config] = tab(at: 100)
		frames.tabs[hvc0] = tab(at: 0)
		#expect(drag.update(
			location: point(48, 15), translation: CGSize(width: -2, height: 0),
			canvas: canvas, frames: frames) == nil)
		#expect(drag.update(
			location: point(47, 15), translation: CGSize(width: -3, height: 0),
			canvas: canvas, frames: frames) == 0)
		#expect(drag.baselineShift == 0)
	}

	@Test func reorderMovesOnePlacePerSample() {
		let (canvas, frames) = onePane()
		var drag = CanvasTabDrag(
			tab: .config, paneID: left, location: point(50, 15), translation: .zero)
		#expect(drag.update(
			location: point(280, 15), translation: CGSize(width: 230, height: 0),
			canvas: canvas, frames: frames) == 1)
		#expect(drag.baselineShift == 100)
	}

	@Test func anUnmeasuredSiblingNeverReorders() {
		var (canvas, frames) = onePane()
		frames.tabs[hvc0] = nil
		var drag = CanvasTabDrag(
			tab: .config, paneID: left, location: point(50, 15), translation: .zero)
		#expect(drag.update(
			location: point(153, 15), translation: CGSize(width: 103, height: 0),
			canvas: canvas, frames: frames) == nil)
		#expect(drag.baselineShift == 0)
		// A tab no pane holds has nothing to reorder against.
		canvas.close(.config)
		var gone = CanvasTabDrag(
			tab: .config, paneID: left, location: point(50, 15), translation: .zero)
		#expect(gone.update(
			location: point(400, 15), translation: CGSize(width: 350, height: 0),
			canvas: canvas, frames: frames) == nil)
	}

	// MARK: - Detach

	@Test func pullingDownMoreThan42PointsDetaches() {
		let (canvas, frames) = onePane()
		var drag = CanvasTabDrag(
			tab: .config, paneID: left, location: point(50, 15), translation: .zero)
		_ = drag.update(
			location: point(50, 15), translation: CGSize(width: 0, height: 42),
			canvas: canvas, frames: frames)
		#expect(!drag.detached)
		// Detached, the drag no longer reorders, even past a midpoint.
		#expect(drag.update(
			location: point(153, 15), translation: CGSize(width: 103, height: 42.5),
			canvas: canvas, frames: frames) == nil)
		#expect(drag.detached)
		#expect(drag.baselineShift == 0)
		_ = drag.update(
			location: point(50, 15), translation: CGSize(width: 0, height: -43),
			canvas: canvas, frames: frames)
		#expect(drag.detached)
	}

	@Test func leavingTheStripsMarginDetachesAndComingBackReattaches() {
		let (canvas, frames) = onePane()
		var drag = CanvasTabDrag(
			tab: .config, paneID: left, location: point(50, 15), translation: .zero)
		// A pull too small to detach on its own.
		func move(to location: CGPoint) -> Bool {
			_ = drag.update(
				location: location, translation: CGSize(width: 0, height: 20),
				canvas: canvas, frames: frames)
			return drag.detached
		}
		#expect(!move(to: point(50, 37)))
		#expect(move(to: point(50, 38)))
		#expect(!move(to: point(-8, 15)))
		#expect(move(to: point(1008, 15)))
		#expect(!move(to: point(50, 15)))
	}

	@Test func anUnmeasuredStripCountsAsInside() {
		let (canvas, measured) = onePane()
		var frames = measured
		frames.strips = [:]
		var drag = CanvasTabDrag(
			tab: .config, paneID: left, location: point(50, 15), translation: .zero)
		_ = drag.update(
			location: point(500, 300), translation: CGSize(width: 450, height: 10),
			canvas: canvas, frames: frames)
		#expect(!drag.detached)
	}

	@Test func theOffsetLiftsAtMostFourPointsAndOnlyTheAttachedTab() {
		let (canvas, frames) = onePane()
		var drag = CanvasTabDrag(
			tab: hvc0, paneID: left, location: point(150, 15), translation: .zero)
		_ = drag.update(
			location: point(160, 25), translation: CGSize(width: 10, height: 10),
			canvas: canvas, frames: frames)
		#expect(drag.offset(for: hvc0) == CGSize(width: 10, height: 2))
		#expect(drag.offset(for: .config) == .zero)
		_ = drag.update(
			location: point(160, 15), translation: CGSize(width: 10, height: 30),
			canvas: canvas, frames: frames)
		#expect(drag.offset(for: hvc0) == CGSize(width: 10, height: 4))
		_ = drag.update(
			location: point(160, 15), translation: CGSize(width: 10, height: -30),
			canvas: canvas, frames: frames)
		#expect(drag.offset(for: hvc0) == CGSize(width: 10, height: -4))
		_ = drag.update(
			location: point(160, 15), translation: CGSize(width: 10, height: 50),
			canvas: canvas, frames: frames)
		#expect(drag.offset(for: hvc0) == .zero)
	}

	// MARK: - Release

	@Test func releasingAnAttachedDragChangesNothing() {
		let (canvas, frames) = onePane()
		let drag = CanvasTabDrag(
			tab: hvc0, paneID: left, location: point(5_000, 5_000), translation: .zero)
		#expect(drag.release(canvas: canvas, frames: frames) == .stay)
	}

	@Test func releasingOutsideTheCanvasMarginTearsOff() {
		let (canvas, frames) = onePane()
		#expect(detachedDrag(to: point(1041, 300), canvas, frames)
			.release(canvas: canvas, frames: frames) == .tearOff)
		#expect(detachedDrag(to: point(-41, 300), canvas, frames)
			.release(canvas: canvas, frames: frames) == .tearOff)
		#expect(detachedDrag(to: point(500, 641), canvas, frames)
			.release(canvas: canvas, frames: frames) == .tearOff)
		// Inside the 40 pt margin and over no zone: nothing happens.
		#expect(detachedDrag(to: point(1039, 300), canvas, frames)
			.release(canvas: canvas, frames: frames) == .stay)
		#expect(detachedDrag(to: point(500, 639), canvas, frames)
			.release(canvas: canvas, frames: frames) == .stay)
	}

	@Test func releasingOverAStripInsertsAmongTheMeasuredTabsLeftOfTheCursor() {
		let (canvas, measured) = twoPanes()
		var frames = measured
		// hvc1's midpoint is 555.
		#expect(detachedDrag(to: point(560, 34), canvas, frames)
			.release(canvas: canvas, frames: frames) == .move(toPane: right, at: 1))
		#expect(detachedDrag(to: point(540, 35), canvas, frames)
			.release(canvas: canvas, frames: frames) == .move(toPane: right, at: 0))
		// The strip reaches 6 pt below its frame; past that (and outside every zone) stays.
		#expect(detachedDrag(to: point(540, 36), canvas, frames)
			.release(canvas: canvas, frames: frames) == .stay)
		// A tab without a measured frame is not counted.
		frames.tabs[hvc1] = nil
		#expect(detachedDrag(to: point(560, 34), canvas, frames)
			.release(canvas: canvas, frames: frames) == .move(toPane: right, at: 0))
	}

	@Test func releasingOnAnotherPaneMovesTheTabToItsEnd() {
		let (canvas, frames) = twoPanes()
		#expect(detachedDrag(to: point(750, 300), canvas, frames)
			.release(canvas: canvas, frames: frames) == .move(toPane: right, at: 1))
		// Its own pane's zone keeps it where it was.
		#expect(detachedDrag(to: point(250, 300), canvas, frames)
			.release(canvas: canvas, frames: frames) == .stay)
		// Between the pane zones, over no edge zone.
		#expect(detachedDrag(to: point(500, 300), canvas, frames)
			.release(canvas: canvas, frames: frames) == .stay)
	}

	@Test func edgeZonesSplitAndWinOverlaps() {
		let (canvas, frames) = twoPanes()
		#expect(detachedDrag(to: point(50, 300), canvas, frames)
			.release(canvas: canvas, frames: frames) == .split(trailing: false))
		#expect(detachedDrag(to: point(950, 300), canvas, frames)
			.release(canvas: canvas, frames: frames) == .split(trailing: true))
		// Inside both the leading split zone (4…114) and the left pane's zone (60…435).
		#expect(detachedDrag(to: point(100, 300), canvas, frames)
			.release(canvas: canvas, frames: frames) == .split(trailing: false))
		#expect(CanvasTabDrag.zone(at: point(100, 300), canvas: canvas, frames: frames)
			== .newLeading)
	}

	// MARK: - Drop zones

	@Test func onePaneOffersBothSplitsAndAZoneInsetByHalfAnEdge() {
		let (canvas, frames) = onePane()
		let zones = CanvasTabDrag.dropZones(canvas: canvas, frames: frames)
		#expect(zones.map(\.zone) == [.newLeading, .newTrailing, .pane(left)])
		// The edge is 11 % of the width (at least 56): 110 here.
		#expect(close(zones[0].rect, CGRect(x: 4, y: 4, width: 110, height: 592)))
		#expect(close(zones[1].rect, CGRect(x: 886, y: 4, width: 110, height: 592)))
		#expect(close(zones[2].rect, CGRect(x: 60, y: 24, width: 880, height: 552)))
	}

	@Test func aNarrowCanvasKeepsA56PointEdge() {
		let canvas = CanvasState(panes: [CanvasPane(id: left, tabs: [.config])])
		let frames = CanvasTabDrag.Frames(
			canvasSize: CGSize(width: 400, height: 300),
			panes: [left: CGRect(x: 0, y: 0, width: 400, height: 300)])
		let zones = CanvasTabDrag.dropZones(canvas: canvas, frames: frames)
		#expect(close(zones[0].rect, CGRect(x: 4, y: 4, width: 56, height: 292)))
		#expect(close(zones[1].rect, CGRect(x: 340, y: 4, width: 56, height: 292)))
		#expect(close(zones[2].rect, CGRect(x: 33, y: 24, width: 334, height: 252)))
	}

	@Test func twoPanesAreBothEdgePanes() {
		let (canvas, frames) = twoPanes()
		let zones = CanvasTabDrag.dropZones(canvas: canvas, frames: frames)
		#expect(zones.map(\.zone) == [.newLeading, .newTrailing, .pane(left), .pane(right)])
		#expect(close(zones[2].rect, CGRect(x: 60, y: 24, width: 375, height: 552)))
		#expect(close(zones[3].rect, CGRect(x: 565, y: 24, width: 375, height: 552)))
	}

	@Test func threePanesOfferNoSplitAndInsetTwelve() {
		let canvas = CanvasState(panes: [
			CanvasPane(id: left, tabs: [.config]), CanvasPane(id: right, tabs: [hvc0]),
			CanvasPane(id: third, tabs: [hvc1]),
		])
		let frames = CanvasTabDrag.Frames(
			canvasSize: CGSize(width: 1000, height: 600),
			panes: [
				left: CGRect(x: 0, y: 0, width: 330, height: 600),
				right: CGRect(x: 335, y: 0, width: 330, height: 600),
				third: CGRect(x: 670, y: 0, width: 330, height: 600),
			])
		let zones = CanvasTabDrag.dropZones(canvas: canvas, frames: frames)
		#expect(zones.map(\.zone) == [.pane(left), .pane(right), .pane(third)])
		#expect(close(zones[0].rect, CGRect(x: 12, y: 24, width: 306, height: 552)))
		#expect(close(zones[2].rect, CGRect(x: 682, y: 24, width: 306, height: 552)))
	}

	@Test func unmeasuredGeometryOffersNoZones() {
		let (canvas, measured) = onePane()
		#expect(CanvasTabDrag.dropZones(canvas: canvas, frames: CanvasTabDrag.Frames()).isEmpty)
		var noPanes = measured
		noPanes.panes = [:]
		#expect(CanvasTabDrag.dropZones(canvas: canvas, frames: noPanes).map(\.zone)
			== [.newLeading, .newTrailing])
	}
}
