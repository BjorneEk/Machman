//
//  TearOffTests.swift
//  MachmanDesktopCoreTests
//
//  Q32: the canvas and the tree each tore a tab off and opened its window a turn later in
//  their own words, and only the tree checked first whether the tab already had a window.
//  Both call VMListViewModel.tearOffAndOpen now.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// L1: view model on StubMachman.
@MainActor
struct TearOffTests {
	private let console = SerialPortRef(kind: .console, index: 0)

	// Runs once everything the main queue already holds has run.
	private func mainQueueTurn() async {
		await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
	}

	@Test("Q32: a tab tears off and opens a turn later; a torn tab's window opens at once")
	func tearOffOpensOnceTheCanvasMountIsGone() async {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		h.open(.terminal(console), vm: "Debian")
		var opened: [TornTab] = []
		let torn = TornTab(vm: "Debian", tab: .terminal(console))

		h.viewModel.tearOffAndOpen(.terminal(console), vm: "Debian") { opened.append($0) }
		// Off the canvas and counted as torn at once; the window waits for the next turn.
		#expect(!h.canvases.canvas(for: "Debian").panes.contains { $0.tabs.contains(torn.tab) })
		#expect(h.tornTabs.open.contains(torn))
		#expect(opened.isEmpty)
		await mainQueueTurn()
		#expect(opened == [torn])

		// Asked again (a second Open in New Window): its window is focused, nothing moves.
		let canvas = h.canvases.canvas(for: "Debian")
		h.viewModel.tearOffAndOpen(.terminal(console), vm: "Debian") { opened.append($0) }
		#expect(opened == [torn, torn])
		#expect(h.canvases.canvas(for: "Debian") == canvas)
	}
}
