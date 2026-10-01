//
//  CommandTargetTests.swift
//  MachmanDesktopCoreTests
//
//  The menu commands' targets for the key window (P22). They used to act on the main window
//  whatever was in front: with a torn terminal key, ⌘S saved the main window's terminal and
//  Paste Items pasted into the main window's VM. CommandTarget resolves the window each
//  scene publishes; the menus (MachmanCommands) only read it.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct CommandTargetTests {
	private let console = SerialPortRef(kind: .console, index: 0)

	private func connect(
		_ h: DesktopHarness, _ vm: String
	) async throws -> any TerminalController {
		h.terminals.ensureController(
			vm: vm, ref: console, socketPath: nil, profile: h.profiles.defaultProfile)
		#expect(await eventually { h.terminals.controller(vm: vm, ref: self.console) != nil })
		return try #require(h.terminals.controller(vm: vm, ref: console))
	}

	@Test func theMainWindowTargetsItsSelection() async throws {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		h.open(.config, vm: "Debian")
		h.open(.terminal(console), vm: "Debian")
		let terminal = try await connect(h, "Debian")
		h.viewModel.treeSelection = [.disk("storage:system")]
		let target = CommandTarget(viewModel: h.viewModel, window: .main)
		#expect(target.vm?.name == "Debian")
		#expect(target.terminal === terminal)
		#expect(target.canCycleTabs)
		#expect(target.copyableItems.map(\.path)
			== ["\(Samples.vmsRoot)/Debian/system.raw"])
		#expect(target.closesCanvasTab)
		#expect(!target.asksOnMainWindow)
	}

	@Test func aTornTerminalTargetsItsOwnTab() async throws {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		h.open(.config, vm: "Debian")
		h.open(.terminal(console), vm: "Debian")
		h.viewModel.treeSelection = [.disk("storage:system")]
		let alpine = try await connect(h, "Alpine")
		let target = CommandTarget(
			viewModel: h.viewModel,
			window: .torn(TornTab(vm: "Alpine", tab: .terminal(console))))
		#expect(target.vm?.name == "Alpine")
		#expect(target.terminal === alpine)
		#expect(!target.canCycleTabs)
		#expect(target.copyableItems.isEmpty)
		#expect(!target.closesCanvasTab)
		#expect(target.asksOnMainWindow)
	}

	// Settings (or nothing) key: the VM commands have nothing to act on.
	@Test func noMachmanWindowTargetsNothing() async {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		let target = CommandTarget(viewModel: h.viewModel, window: nil)
		#expect(target.vm == nil)
		#expect(target.terminal == nil)
		#expect(!target.closesCanvasTab)
		#expect(!target.asksOnMainWindow)
		let disconnected = CommandTarget(viewModel: nil, window: .main)
		#expect(disconnected.vm == nil)
	}

	// A torn session window restored after a relaunch shows its VM, but has no terminal to
	// save.
	@Test func aRestoredTornSessionHasNoTerminal() async {
		let h = await DesktopHarness.make()
		let session = SSHSessionRef(title: "Session 1")
		let target = CommandTarget(
			viewModel: h.viewModel, window: .torn(TornTab(vm: "Debian", tab: .ssh(session))))
		#expect(target.vm?.name == "Debian")
		#expect(target.terminal == nil)
	}

	// File ▸ New VM… (⌘N) asks the toolbar picker for its template page.
	@Test func requestNewVMRaisesTheChooserFlag() async {
		let h = await DesktopHarness.make()
		#expect(!h.viewModel.newVMChooserRequested)
		h.viewModel.requestNewVM()
		#expect(h.viewModel.newVMChooserRequested)
	}
}
