//
//  ReconnectWindowStateTests.swift
//  MachmanDesktopUITests
//
//  T32: the inspector's visibility and the tree's selection lived on the per-connection view
//  model, so every agent reconnect (a replace, a crash, the pkill the dev notes recommend)
//  shut the inspector and lost the selected disk or port, while the selected VM survived in
//  the app's own state. All three live in the main window's state now, which the remounted
//  window gives back to the fresh view model.
//

import SwiftUI
import Testing
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

// L1: desktop views hosted offscreen (chrome .window).
@MainActor
struct ReconnectWindowStateTests {
	// The app's @State: one value the window binds to, outliving each view model.
	@MainActor
	final class WindowStateBox {
		var state = MainWindowState(selection: "Debian")
	}

	@Test("T32: the main window keeps its inspector and tree selection across a reconnect")
	func aReconnectKeepsTheWindowState() async throws {
		let h = await UIHarness.make(select: "Debian")
		let box = WindowStateBox()
		let state = Binding(get: { box.state }, set: { box.state = $0 })
		let disk = SidebarNode.disk("storage:system")
		try await OffscreenHost.withHost(
			VMNavigationView(viewModel: h.viewModel, windowState: state, profiles: h.profiles),
			width: 1200, height: 800, chrome: .window
		) { hosted in
			await hosted.settle()
			h.viewModel.treeSelection = [disk]
			h.viewModel.showInfoPanel = true
			await hosted.settle()
		}

		let next = h.reconnectedViewModel()
		try await OffscreenHost.withHost(
			VMNavigationView(viewModel: next, windowState: state, profiles: h.profiles),
			width: 1200, height: 800, chrome: .window
		) { hosted in
			await hosted.settle()
			#expect(await eventually { next.selectedName == "Debian" })
			#expect(next.showInfoPanel)
			#expect(next.treeSelection == [disk])
		}
	}
}
