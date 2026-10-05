//
//  MenuBarWindowItemTests.swift
//  MachmanUITests
//
//  P27 (W2-21): the agent's menu offers Open Window and Close Window only for a running VM
//  with a display, each by whether the window is open. The menu itself is drawn by the
//  agent's app target; the model behind it decides what is enabled.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
import MachmanUI

// L1: rules (MenuBarModel on StubMachman).
@MainActor
struct MenuBarWindowItemTests {
	@Test("W2-21: the agent menu offers no window item for a VM without a display")
	func noWindowItemWithoutADisplay() {
		let model = MenuBarModel(api: StubMachman())
		let headless = Samples.linuxNoDisplay(state: .running)
		#expect(!headless.hasEnabledGraphics)
		#expect(!model.isEnabled(.openWindow, headless))
		#expect(!model.isEnabled(.closeWindow, headless))

		var closed = Samples.linux(state: .running)
		closed.windowOpen = false
		#expect(model.isEnabled(.openWindow, closed))
		#expect(!model.isEnabled(.closeWindow, closed))

		let open = Samples.linux(state: .running)
		#expect(open.windowOpen)
		#expect(!model.isEnabled(.openWindow, open))
		#expect(model.isEnabled(.closeWindow, open))

		let stopped = Samples.linux()
		#expect(!model.isEnabled(.openWindow, stopped))
		#expect(!model.isEnabled(.closeWindow, stopped))
	}
}
