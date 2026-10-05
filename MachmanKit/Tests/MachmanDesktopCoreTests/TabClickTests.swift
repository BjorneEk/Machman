//
//  TabClickTests.swift
//  MachmanDesktopCoreTests
//
//  Clicking a canvas tab or pane brings the inspector to it (T23). The tree followed the
//  canvas only when the active tab changed, so clicking the tab already active — the console
//  you're typing in, after selecting a disk — left the inspector on the disk, and a click in
//  an inactive pane's content didn't make that pane active at all.
//

import Testing
import Foundation
import Combine
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct TabClickTests {
	private let console = SerialPortRef(kind: .console, index: 0)
	private let disk = SidebarNode.disk("storage:system")

	private func debian() async -> DesktopHarness {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		return h
	}

	@Test func clickingTheActiveTabAfterADiskSelectsItsRow() async {
		let h = await debian()
		h.open(.terminal(console), vm: "Debian")
		h.viewModel.treeSelectionChanged([disk])
		h.viewModel.tabClicked(.terminal(console), vm: "Debian")
		#expect(h.viewModel.treeSelection == [.serial(console)])
	}

	@Test func clickingAnotherTabActivatesItAndSelectsItsRow() async {
		let h = await debian()
		h.open(.config, vm: "Debian")
		h.open(.terminal(console), vm: "Debian")
		h.viewModel.tabClicked(.config, vm: "Debian")
		#expect(h.canvases.canvas(for: "Debian").activeTab == .config)
		#expect(h.viewModel.treeSelection == [.vmRoot])
	}

	@Test func clickingAPaneActivatesItAndSelectsItsTabsRow() async throws {
		let h = await debian()
		h.open(.config, vm: "Debian")
		h.open(.terminal(console), vm: "Debian")
		var canvas = h.canvases.canvas(for: "Debian")
		canvas.split(.terminal(console))
		h.canvases.setCanvas(canvas, for: "Debian")
		let first = try #require(h.canvases.canvas(for: "Debian").panes.first)
		#expect(h.canvases.canvas(for: "Debian").activePaneID != first.id)
		h.viewModel.paneClicked(first.id, vm: "Debian")
		#expect(h.canvases.canvas(for: "Debian").activePaneID == first.id)
		#expect(h.viewModel.treeSelection == [.vmRoot])
	}

	@Test func aClickThatChangesNoTabWritesNoCanvas() async throws {
		let h = await debian()
		h.open(.terminal(console), vm: "Debian")
		let pane = try #require(h.canvases.canvas(for: "Debian").activePane)
		var writes = 0
		let watch = h.canvases.objectWillChange.sink { writes += 1 }
		h.viewModel.tabClicked(.terminal(console), vm: "Debian")
		h.viewModel.paneClicked(pane.id, vm: "Debian")
		watch.cancel()
		#expect(writes == 0)
		#expect(h.viewModel.treeSelection == [.serial(console)])
	}
}
