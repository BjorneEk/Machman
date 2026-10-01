//
//  RevealTabTests.swift
//  MachmanDesktopCoreTests
//
//  Showing a tab honours its single mount (T21): a tab torn into its own window is focused
//  there, never opened a second time in the canvas. The empty canvas's Open button skipped
//  this check and duplicated a torn configuration tab; it, the tree and the canvas's own
//  "nothing open" fallback now share this rule.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct RevealTabTests {
	private let console = SerialPortRef(kind: .console, index: 0)

	@Test func aTornConfigurationIsFocusedNotDuplicated() async {
		let h = await DesktopHarness.make()
		let torn = TornTab(vm: "Debian", tab: .config)
		h.tornTabs.open.insert(torn)
		#expect(h.viewModel.revealTab(.config, vm: "Debian") == torn)
		#expect(h.canvases.canvas(for: "Debian").allOpenTabs.isEmpty)
	}

	@Test func anUntornConfigurationOpensInTheCanvas() async {
		let h = await DesktopHarness.make()
		#expect(h.viewModel.revealTab(.config, vm: "Debian") == nil)
		#expect(h.canvases.canvas(for: "Debian").activeTab == .config)
		// Open-or-focus: a second reveal never duplicates it.
		h.open(.terminal(console), vm: "Debian")
		#expect(h.viewModel.revealTab(.config, vm: "Debian") == nil)
		#expect(h.canvases.canvas(for: "Debian").allOpenTabs == [.config, .terminal(console)])
		#expect(h.canvases.canvas(for: "Debian").activeTab == .config)
	}

	@Test func aTornTerminalIsFocused() async {
		let h = await DesktopHarness.make()
		let torn = TornTab(vm: "Debian", tab: .terminal(console))
		h.tornTabs.open.insert(torn)
		#expect(h.viewModel.revealTab(.terminal(console), vm: "Debian") == torn)
		#expect(h.canvases.canvas(for: "Debian").allOpenTabs.isEmpty)
	}

	// Session rows exist only for open sessions: revealing one never opens a new tab.
	@Test func aSessionIsActivatedNeverOpened() async {
		let h = await DesktopHarness.make()
		let session = SSHSessionRef(title: "Session 1")
		#expect(h.viewModel.revealTab(.ssh(session), vm: "Debian") == nil)
		#expect(h.canvases.canvas(for: "Debian").allOpenTabs.isEmpty)
	}
}
