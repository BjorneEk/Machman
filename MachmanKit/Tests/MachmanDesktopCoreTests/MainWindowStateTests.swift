//
//  MainWindowStateTests.swift
//  MachmanDesktopCoreTests
//
//  T32: a reconnect makes a fresh view model, which used to start with the inspector shut and
//  no tree selection. MainWindowState keeps both beside the selected VM, and gives them back
//  — the rows only while they still exist, and never over a VM the list already chose.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// L1: view models on StubMachman.
@MainActor
struct MainWindowStateTests {
	// What DaemonConnection makes for a new connection: a view model over the same stores.
	private func reconnected(_ h: DesktopHarness) -> VMListViewModel {
		VMListViewModel(
			api: h.stub, store: h.store, operations: h.operations, terminals: h.terminals,
			previews: h.previews, canvases: h.canvases, tornTabs: h.tornTabs,
			profiles: h.profiles)
	}

	@Test("T32: a reconnect's fresh view model gets the inspector and tree selection back")
	func aFreshViewModelGetsTheWindowBack() async throws {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		var state = MainWindowState(selection: "Debian")
		state.treeSelection = [.disk("storage:system"), .disk("storage:gone")]
		state.inspectorShown = true

		let next = reconnected(h)
		state.restore(into: next)
		#expect(next.selectedName == "Debian")
		#expect(next.showInfoPanel)
		#expect(next.treeSelection == [.disk("storage:system")])   // the gone disk stays gone
	}

	@Test("T32: a restore leaves a VM the list chose meanwhile, and its rows, alone")
	func aRestoreNeverOverridesTheListsChoice() async throws {
		let h = await DesktopHarness.make()
		var state = MainWindowState(selection: "Debian")
		state.treeSelection = [.disk("storage:system")]
		let next = reconnected(h)
		next.select(name: "Alpine")
		state.restore(into: next)
		#expect(next.selectedName == "Alpine")
		#expect(next.treeSelection.isEmpty)
		#expect(!next.showInfoPanel)
	}
}
