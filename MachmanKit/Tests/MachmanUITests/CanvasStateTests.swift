import Testing
import Foundation
import MachmanAPI
import MachmanUI

// The split-canvas layout rules: open/focus, close fallbacks, pane collapse, moves with
// drag-style indices, the 3-pane cap, reconciliation, fraction clamps, and the persistence
// round-trip.
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

	@Test func closeFallsBackToANeighbour() {
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

	@Test func reorderRepositionsWithoutActivating() {
		var canvas = CanvasState()
		canvas.open(.config)
		canvas.open(.terminal(hvc0))
		canvas.open(.terminal(hvc1))
		canvas.activate(.config)
		canvas.reorder(.config, to: 2)
		#expect(canvas.panes[0].tabs == [.terminal(hvc0), .terminal(hvc1), .config])
		#expect(canvas.activeTab == .config)
		canvas.reorder(.terminal(hvc1), to: 0)
		#expect(canvas.panes[0].tabs == [.terminal(hvc1), .terminal(hvc0), .config])
		#expect(canvas.activeTab == .config)
	}

	@Test("H67: Split Right needs other tabs in the pane, and lands right of that pane")
	func splitRightStaysBesideItsPane() {
		var canvas = CanvasState()
		canvas.open(.config)
		#expect(!canvas.canSplitRight(.config))   // a lone tab: the same layout again
		canvas.splitRight(.config)
		#expect(canvas.panes.count == 1)
		#expect(canvas.panes[0].tabs == [.config])

		canvas.open(.terminal(hvc0))
		canvas.open(.terminal(hvc1))
		canvas.split(.terminal(hvc1))              // the drop zone's edge split
		let right = canvas.panes[1].id
		#expect(canvas.canSplitRight(.terminal(hvc0)))
		#expect(!canvas.canSplitRight(.terminal(hvc1)))   // alone in its pane
		canvas.splitRight(.terminal(hvc0))
		#expect(canvas.panes.map(\.tabs) == [[.config], [.terminal(hvc0)], [.terminal(hvc1)]])
		#expect(canvas.panes[2].id == right)
		#expect(canvas.activeTab == .terminal(hvc0))
		#expect(!canvas.canSplitRight(.config))   // the cap: three panes
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

	// MARK: - SSH session tabs (ephemeral)

	@Test func sshTabsOpenCloseAndActivateLikeTabs() {
		let ref = SSHSessionRef(title: "admin@192.168.64.9")
		var canvas = CanvasState()
		canvas.open(.config)
		canvas.open(.ssh(ref))
		#expect(canvas.activeTab == .ssh(ref))
		#expect(canvas.allOpenTabs.contains(.ssh(ref)))
		canvas.close(.ssh(ref))
		#expect(!canvas.allOpenTabs.contains(.ssh(ref)))
	}

	@Test func strippingEphemeralTabsDropsOnlySSH() {
		let ref = SSHSessionRef(title: "admin@192.168.64.9")
		var canvas = CanvasState()
		canvas.open(.config)
		canvas.open(.terminal(hvc0))
		canvas.open(.ssh(ref))
		// A pane holding ONLY the ssh tab collapses on strip, like a live close would.
		canvas.split(.ssh(ref))
		let stripped = canvas.strippingEphemeralTabs()
		#expect(!stripped.allOpenTabs.contains(.ssh(ref)))
		#expect(stripped.allOpenTabs.contains(.terminal(hvc0)))
		#expect(stripped.allOpenTabs.contains(.config))
		#expect(stripped.panes.count == 1)
	}

	@Test func sshTabCodingRoundTripsAndTitleSurvives() throws {
		let ref = SSHSessionRef(title: "admin@192.168.64.9")
		let data = try JSONEncoder().encode(VMPaneTab.ssh(ref))
		#expect(String(decoding: data, as: UTF8.self).contains(#""kind":"ssh""#))
		#expect(try JSONDecoder().decode(VMPaneTab.self, from: data) == .ssh(ref))
	}

	// MARK: - Loading layouts another build wrote (T12)

	private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
		try JSONDecoder().decode(type, from: Data(json.utf8))
	}

	private let paneA = "0A000000-0000-4000-8000-00000000000A"
	private let paneB = "0B000000-0000-4000-8000-00000000000B"
	private let hvc0JSON = #"{"kind":"terminal","port":{"kind":"console","index":0}}"#

	@Test func unknownTabKindsAreDroppedNotTurnedIntoConfig() throws {
		let pane = try decode(CanvasPane.self, """
			{"id": "\(paneA)", "tabs": [{"kind": "config"}, {"kind": "history"},
			  {"kind": "notes"}, \(hvc0JSON)], "active": {"kind": "history"}}
			""")
		#expect(pane.tabs == [.config, .terminal(hvc0)])
		#expect(pane.active == .config)
	}

	@Test func aRepeatedTabInOnePaneIsKeptOnce() throws {
		let pane = try decode(CanvasPane.self, """
			{"id": "\(paneA)", "tabs": [\(hvc0JSON), {"kind": "config"}, \(hvc0JSON)]}
			""")
		#expect(pane.tabs == [.terminal(hvc0), .config])
	}

	@Test func aTabInTwoPanesStaysInTheFirst() throws {
		let canvas = try decode(CanvasState.self, """
			{"panes": [{"id": "\(paneA)", "tabs": [{"kind": "config"}, \(hvc0JSON)]},
			           {"id": "\(paneB)", "tabs": [\(hvc0JSON)]}],
			 "activePaneID": "\(paneB)", "fractions": [0.5, 0.5]}
			""")
		#expect(canvas.panes.count == 1)
		#expect(canvas.allOpenTabs == [.config, .terminal(hvc0)])
		#expect(canvas.activePaneID == UUID(uuidString: paneA))
		#expect(canvas.fractions == [1.0])
	}

	@Test func aDanglingActivePaneFallsBackToTheFirst() throws {
		let canvas = try decode(CanvasState.self, """
			{"panes": [{"id": "\(paneA)", "tabs": [{"kind": "config"}]}],
			 "activePaneID": "\(paneB)", "fractions": [1.0]}
			""")
		#expect(canvas.activePaneID == UUID(uuidString: paneA))
	}

	@Test func aRepeatedPaneIDIsMadeUnique() throws {
		let canvas = try decode(CanvasState.self, """
			{"panes": [{"id": "\(paneA)", "tabs": [{"kind": "config"}]},
			           {"id": "\(paneA)", "tabs": [\(hvc0JSON)]}],
			 "activePaneID": "\(paneA)", "fractions": [0.5, 0.5]}
			""")
		#expect(canvas.panes.count == 2)
		#expect(Set(canvas.panes.map(\.id)).count == 2)
		#expect(canvas.fractions == [0.5, 0.5])
	}

	// A torn-off window must always show something: its standalone tab decode keeps
	// turning an unknown kind into the config tab (canvases drop such tabs instead).
	@Test func aTornWindowOfAnUnknownKindStillOpensAsConfig() throws {
		let torn = try decode(TornTab.self, #"{"vm": "Debian", "tab": {"kind": "history"}}"#)
		#expect(torn.tab == .config)
	}
}
