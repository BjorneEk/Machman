//
//  WindowFloorTests.swift
//  MachmanDesktopUITests
//
//  The main window's floors and its toolbar, from VMNavigationView hosted offscreen in a
//  titled, never-ordered window at its fitting size: the floor with the inspector open and
//  closed (W3-39, L1) and with three canvas panes (W3-61, L2), the toolbar's safe chip only
//  in a safe run (15), and the inspector toggle's name (W4-27, H32). The numbers are the
//  rows' (±16 pt, T22) and match the window.main.*floor renders (2× PNGs). The » overflow,
//  growing the window and frame restore are live-window behaviour (manual).
//

import SwiftUI
import Testing
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

// L1: desktop views hosted offscreen (chrome .window), read through in-process accessibility.
@MainActor
struct WindowFloorTests {
	static let tolerance: CGFloat = 16
	static let safeHelp = "Safe mode \u{2014} changes are discarded on stop"

	private func window(_ h: UIHarness, _ name: String) -> some View {
		VMNavigationView(
			viewModel: h.viewModel, selection: .constant(name), profiles: h.profiles)
	}

	// The window's size (nil: its fitting size, the floor) and its tree, toolbar included.
	private func floor(
		_ h: UIHarness, _ name: String, width: CGFloat? = nil, height: CGFloat? = nil
	) async throws -> (CGSize, AXSnapshot) {
		h.viewModel.select(name: name)
		return try await OffscreenHost.withHost(
			window(h, name), width: width, height: height, chrome: .window
		) { ($0.bounds.size, $0.snapshot()) }
	}

	// Wide enough for every toolbar item: at the floor some go behind the » overflow.
	private func roomy(_ h: UIHarness, _ name: String) async throws -> AXSnapshot {
		try await floor(h, name, width: 1280, height: 720).1
	}

	private func about(_ value: CGFloat, _ target: CGFloat) -> Bool {
		abs(value - target) <= Self.tolerance
	}

	private func toolbar(_ tree: AXSnapshot) -> AXSnapshot? {
		tree.all.first { $0.role == "AXToolbar" }
	}

	@Test("W3-39: the main window floors at about 878 open and 578 closed")
	func theWindowFloors() async throws {
		#expect(MainWindowLayout.canvasMinWidth(panes: 1) == 300)
		#expect(MainWindowLayout.canvasMinWidth(panes: 2) == 300)
		#expect(MainWindowLayout.canvasMinWidth(panes: 3) == 378)
		#expect(MainWindowLayout.sidebar.min == 230)
		#expect(MainWindowLayout.inspector.min == 250)

		let h = await UIHarness.make(select: "Debian")
		h.viewModel.showInfoPanel = true
		let (open, _) = try await floor(h, "Debian")
		#expect(about(open.width, 878) && about(open.height, 352), "open: \(open)")
		h.viewModel.showInfoPanel = false
		let (closed, _) = try await floor(h, "Debian")
		#expect(about(closed.width, 578) && about(closed.height, 352), "closed: \(closed)")
		// Opening the inspector raises the floor by about its own minimum.
		#expect(about(open.width - closed.width, 300), "\(open) vs \(closed)")
	}

	@Test("W3-61: three canvas panes raise the closed floor to about 656")
	func threePanesRaiseTheFloor() async throws {
		let h = await UIHarness.make(select: "Kernel Lab")
		// WindowScenes.threePanes: configuration, Console 0 and UART 0 side by side.
		var canvas = h.canvases.canvas(for: "Kernel Lab")
		let console = SerialPortRef(kind: .console, index: 0)
		let uart = SerialPortRef(kind: .uart, index: 0)
		canvas.open(.config)
		canvas.open(.terminal(console))
		canvas.open(.terminal(uart))
		canvas.split(.terminal(console))
		canvas.split(.terminal(uart))
		h.canvases.setCanvas(canvas, for: "Kernel Lab")
		#expect(h.canvases.canvas(for: "Kernel Lab").panes.count == 3)
		h.viewModel.showInfoPanel = false
		let (closed, _) = try await floor(h, "Kernel Lab")
		#expect(about(closed.width, 656) && about(closed.height, 352), "\(closed)")
	}

	@Test("15: the toolbar's safe chip shows only while the VM runs safe")
	func theSafeChipShowsOnlyInASafeRun() async throws {
		let h = await UIHarness.make(
			[Samples.linuxSafeRun("Debian"), Samples.linux("Alpine", state: .running)])
		h.viewModel.showInfoPanel = false
		let safe = try await roomy(h, "Debian")
		let safeBar = try #require(toolbar(safe), "\(safe.dump())")
		#expect(safeBar.all.contains { $0.help == Self.safeHelp }, "\(safeBar.dump())")
		let plain = try await roomy(h, "Alpine")
		let plainBar = try #require(toolbar(plain))
		#expect(!plainBar.all.contains { $0.help == Self.safeHelp }, "\(plainBar.dump())")
	}

	@Test("W4-27: the main toolbar's inspector toggle reads Show or Hide Inspector")
	func theInspectorToggleReadsItsName() async throws {
		let h = await UIHarness.make(select: "Debian")
		h.viewModel.showInfoPanel = true
		let shown = try await roomy(h, "Debian")
		#expect(shown.find(label: "Hide Inspector") != nil, "\(shown.dump())")
		h.viewModel.showInfoPanel = false
		let hidden = try await roomy(h, "Debian")
		#expect(hidden.find(label: "Show Inspector") != nil, "\(hidden.dump())")
		#expect(hidden.find(label: "Hide Inspector") == nil)
	}
}
