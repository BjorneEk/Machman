//
//  CanvasDividerDragTests.swift
//  MachmanUITests
//
//  A divider drag lives in the canvas's view state and is stored once, on release (P9).
//  Each drag event used to write CanvasStateStore and re-render the whole window chain.
//

import Testing
import Foundation
import CoreGraphics
import MachmanAPI
import MachmanUI

struct CanvasDividerDragTests {
	private let canvas = CanvasState(panes: [
		CanvasPane(tabs: [.config]),
		CanvasPane(tabs: [.terminal(SerialPortRef(kind: .console, index: 0))]),
	])

	@Test func theFractionsFollowTheDragFromItsStart() {
		var drag = CanvasDividerDrag(index: 0, canvas: canvas)
		drag.update(translation: 100, available: 1000)
		#expect(abs(drag.fractions[0] - 0.6) < 1e-9)
		#expect(abs(drag.fractions[1] - 0.4) < 1e-9)
		// Each sample measures from the start, not from the previous sample.
		drag.update(translation: 50, available: 1000)
		#expect(abs(drag.fractions[0] - 0.55) < 1e-9)
		#expect(canvas.fractions == [0.5, 0.5])
	}

	@Test func theDragClampsLikeTheCanvas() {
		var drag = CanvasDividerDrag(index: 0, canvas: canvas)
		drag.update(translation: 5000, available: 1000)
		var expected = canvas
		expected.setFraction(5.5, at: 0)
		#expect(drag.fractions == expected.fractions)
	}

	@Test func releasingStoresOneLayout() {
		var drag = CanvasDividerDrag(index: 0, canvas: canvas)
		drag.update(translation: -120, available: 1000)
		var expected = canvas
		expected.setFraction(0.38, at: 0)
		let stored = drag.committed(to: canvas)
		#expect(abs(stored.fractions[0] - expected.fractions[0]) < 1e-9)
		#expect(stored.panes == canvas.panes)
	}

	// Review F18: a drag left over from a layout that changed under it isn't reused.
	@Test func aDragFitsOnlyTheLayoutItStartedOn() {
		let drag = CanvasDividerDrag(index: 0, canvas: canvas)
		#expect(drag.fits(canvas))
		var collapsed = canvas
		collapsed.close(.terminal(SerialPortRef(kind: .console, index: 0)))
		#expect(collapsed.panes.count == 1)
		#expect(!drag.fits(collapsed))
	}
}
