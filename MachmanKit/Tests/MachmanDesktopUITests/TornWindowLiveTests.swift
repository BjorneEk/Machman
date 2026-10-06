//
//  TornWindowLiveTests.swift
//  MachmanDesktopUITests
//
//  A torn window shows its VM from the store itself (P9). It used to read the list through
//  the connection, which republished every change of the view model — and so re-rendered
//  every torn window on each progress tick, toast and tab click. The connection publishes
//  only its own changes now (status, a new view model).
//

import SwiftUI
import Testing
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

// L1: desktop views hosted offscreen, read through in-process accessibility.
@MainActor
struct TornWindowLiveTests {
	// A connection that never republishes: what the window shows must come from the stores
	// it observes itself.
	@MainActor
	final class QuietConnection: TornTabConnection {
		let viewModel: VMListViewModel?
		let terminals: TerminalSessions
		let vmStore: VMStore

		init(_ h: UIHarness) {
			viewModel = h.viewModel
			terminals = h.terminals
			vmStore = h.store
		}
	}

	@Test("P9: a torn window follows its VM through the store, not the connection")
	func aTornWindowFollowsTheStore() async throws {
		let h = await UIHarness.make()
		let window = TornTabWindowView(
			connection: QuietConnection(h), profiles: h.profiles,
			payload: TornTab(vm: "Alpine", tab: .config))
		try await OffscreenHost.withHost(window, width: 640, height: 480) { hosted in
			await hosted.settle()
			#expect(hosted.snapshot().find(text: "Alpine is gone") == nil)
			try await h.stub.deleteVM(named: "Alpine")
			#expect(await eventually { !h.store.vms.contains { $0.name == "Alpine" } })
			await hosted.settle()
			let tree = hosted.snapshot()
			#expect(tree.find(text: "Alpine is gone") != nil, "\(tree.dump())")
		}
	}
}
