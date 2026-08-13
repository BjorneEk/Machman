import Testing
import Foundation
import MachmanAPI
import MachmanUI

// The split-canvas layout rules (CanvasState generalizes VMTabState): open/focus, close
// fallbacks, pane collapse, moves with drag-style indices, the 3-pane cap, reconciliation,
// fraction clamps, and the persistence round-trip.
struct CanvasStateTests {

	private let hvc0 = SerialPortRef(kind: .console, index: 0)
	private let hvc1 = SerialPortRef(kind: .console, index: 1)
	private let tty0 = SerialPortRef(kind: .uart, index: 0)

	@Test func openFocusesAndNeverDuplicates() {
		var canvas = CanvasState()
		canvas.open(.config)
		canvas.open(.terminal(hvc0))
		canvas.open(.terminal(hvc0))   // focus, not duplicate
		#expect(canvas.allOpenTabs == [.config, .terminal(hvc0)])
		#expect(canvas.activeTab == .terminal(hvc0))
		canvas.activate(.config)
		#expect(canvas.activeTab == .config)
		canvas.activate(.terminal(tty0))   // not open: ignored
		#expect(canvas.activeTab == .config)
	}

	@Test func closeFallsBackLikeVMTabState() {
		var canvas = CanvasState()
		canvas.open(.terminal(hvc0))
		canvas.open(.terminal(hvc1))
		canvas.open(.terminal(tty0))
		canvas.activate(.terminal(hvc1))
		canvas.close(.terminal(hvc1))     // right neighbour slides in
		#expect(canvas.activeTab == .terminal(tty0))
		canvas.close(.terminal(tty0))     // closing the last: left neighbour
		#expect(canvas.activeTab == .terminal(hvc0))
	}

	@Test func splitCapsAtThreeAndCollapseRestoresOne() {
		var canvas = CanvasState()
		canvas.open(.config)
		canvas.open(.terminal(hvc0))
		canvas.open(.terminal(hvc1))
		canvas.split(.terminal(hvc0))
		#expect(canvas.panes.count == 2)
		#expect(canvas.fractions == [0.5, 0.5])
		canvas.split(.terminal(hvc1))
		#expect(canvas.panes.count == 3)
		canvas.open(.terminal(tty0))      // joins the active (newest split) pane
		canvas.split(.terminal(tty0))     // cap: no fourth pane
		#expect(canvas.panes.count == 3)
		// Closing each pane's last tab collapses it; fractions renormalize.
		canvas.close(.terminal(hvc0))
		canvas.close(.terminal(hvc1))
		canvas.close(.terminal(tty0))
		#expect(canvas.panes.count == 1)
		#expect(canvas.fractions == [1.0])
		#expect(canvas.activePaneID == canvas.panes.first?.id)
	}

	@Test func moveUsesDragStyleIndices() {
		var canvas = CanvasState()
		canvas.open(.config)
		canvas.open(.terminal(hvc0))
		canvas.split(.terminal(hvc0))
		let right = canvas.panes[1].id
		// Move config into the right pane at position 0 (index computed sans moved tab).
		canvas.move(.config, toPane: right, at: 0)
		#expect(canvas.panes.count == 1)   // left pane emptied and collapsed
		#expect(canvas.panes[0].tabs == [.config, .terminal(hvc0)])
		#expect(canvas.activeTab == .config)
		// Same-pane repositioning.
		canvas.move(.config, toPane: canvas.panes[0].id, at: 1)
		#expect(canvas.panes[0].tabs == [.terminal(hvc0), .config])
	}

	@Test func reconcileDropsGonePortsAcrossPanes() {
		var canvas = CanvasState()
		canvas.open(.config)
		canvas.open(.terminal(hvc0))
		canvas.open(.terminal(hvc1))
		canvas.split(.terminal(hvc1))
		let removed = canvas.reconcile(existing: [hvc0])
		#expect(removed == [hvc1])
		#expect(canvas.panes.count == 1)   // the split pane lost its only tab
		#expect(canvas.allOpenTabs == [.config, .terminal(hvc0)])
		// The config tab always survives reconciliation.
		let none = canvas.reconcile(existing: [])
		#expect(none == [hvc0])
		#expect(canvas.allOpenTabs == [.config])
	}

	@Test func fractionsClampAtMinimumPaneWidth() {
		var canvas = CanvasState()
		canvas.open(.config)
		canvas.open(.terminal(hvc0))
		canvas.split(.terminal(hvc0))
		canvas.setFraction(0.9, at: 0)
		#expect(canvas.fractions[0] == 0.85)   // pair - 0.15
		canvas.setFraction(0.05, at: 0)
		#expect(canvas.fractions[0] == 0.15)
	}

	@Test func codableRoundTripPreservesLayout() throws {
		var canvas = CanvasState()
		canvas.open(.config)
		canvas.open(.terminal(hvc0))
		canvas.open(.terminal(tty0))
		canvas.split(.terminal(tty0))
		canvas.setFraction(0.3, at: 0)
		let data = try JSONEncoder().encode(canvas)
		let decoded = try JSONDecoder().decode(CanvasState.self, from: data)
		#expect(decoded == canvas)
		// The tab coding is the stable tagged shape, not a synthesized positional one.
		let json = String(decoding: data, as: UTF8.self)
		#expect(json.contains(#""kind":"terminal""#))
		#expect(json.contains(#""kind":"config""#))
	}
}
