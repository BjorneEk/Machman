//
//  MenuModelTests.swift
//  MachmanDesktopCoreTests
//
//  The app menus as the user reads them (Q19): titles, shortcuts, what is dimmed and why,
//  and what an item does, for the main window, a torn window and no Machman window in front.
//  The menus were built in the app target, out of every test's reach; MachmanCommands now
//  only renders MenuModel's content. And they republish only when what they show changes
//  (P9).
//

import Testing
import Foundation
import SwiftUI
import Combine
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct MenuModelTests {
	private let console = SerialPortRef(kind: .console, index: 0)

	private func menus(_ h: DesktopHarness) -> MenuModel {
		let menu = MenuModel()
		menu.follow(h.viewModel)
		return menu
	}

	private func content(
		_ menu: MenuModel, _ window: CommandWindow? = .main, inspectorShown: Bool? = false,
		editingText: Bool = false, canPaste: Bool = false
	) -> MenuContent {
		menu.content(
			window: window, inspectorShown: inspectorShown, editingText: editingText,
			canPaste: canPaste)
	}

	@Test("W2-21: the View menu offers no window item for a VM without a display")
	func noWindowItemWithoutADisplay() async {
		var closed = Samples.linux("Fedora", state: .running)
		closed.windowOpen = false
		let h = await DesktopHarness.make([
			Samples.linuxNoDisplay("Debian", state: .running), closed,
			Samples.linux("Alpine", state: .running), Samples.linux("Arch"),
		])
		let view = content(menus(h)).view.items
		#expect(!view.contains { $0.id == "view.window.Debian" })
		#expect(view.first { $0.id == "view.window.Fedora" }?.title == "Open Fedora Window")
		#expect(view.first { $0.id == "view.window.Alpine" }?.title == "Close Alpine Window")
		#expect(!view.contains { $0.id == "view.window.Arch" })
	}

	@Test(
		"""
		W2-22: the File menu holds New VM…, Duplicate…, Save as New VM…, Delete VM… and \
		Save Terminal…, and no New Window
		""")
	func theFileMenu() async {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Alpine")
		let file = content(menus(h)).file.items
		#expect(file.map(\.title) == [
			"New VM\u{2026}", "Duplicate\u{2026}", "Save as New VM\u{2026}", "Delete VM\u{2026}",
			"Save Terminal\u{2026}",
		])
		#expect(file.map(\.shortcut) == [
			KeyboardShortcut("n"), KeyboardShortcut("d"), nil,
			KeyboardShortcut(.delete, modifiers: .command), KeyboardShortcut("s"),
		])
		#expect(file.map(\.isEnabled) == [true, true, false, true, false])
	}

	// A torn Alpine console in front while the main window shows Debian.
	@Test(
		"""
		W2-23: with a torn terminal key, Run names its VM, Next Tab is off and Save Terminal \
		saves its terminal
		""")
	func aTornTerminalIsTheTarget() async throws {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		h.open(.config, vm: "Debian")
		h.open(.terminal(console), vm: "Debian")
		let torn = TornTab(vm: "Alpine", tab: .terminal(console))
		h.tornTabs.open.insert(torn)
		h.terminals.ensureController(
			vm: "Alpine", ref: console, socketPath: nil, profile: h.profiles.defaultProfile)
		let menu = menus(h)
		#expect(await eventually { menu.facts.targets[.torn(torn)]?.hasTerminal == true })
		let shown = content(menu, .torn(torn), inspectorShown: false, canPaste: true)
		#expect(shown.run.items.first?.title == "Start Alpine")
		#expect(shown.run.items.first?.shortcut == KeyboardShortcut("r"))
		#expect(shown.view.items.first { $0.action == .nextTab }?.isEnabled == false)
		#expect(shown.view.items.first { $0.action == .toggleInspector }?.isEnabled == true)
		#expect(shown.edit.items.first { $0.action == .pasteItems }?.isEnabled == true)
		let save = try #require(shown.file.items.first { $0.action == .saveTerminal })
		#expect(save.isEnabled)
		guard case .saveTerminal(let terminal)? = menu.perform(.saveTerminal, window: .torn(torn))
		else {
			Issue.record("Save Terminal saved nothing")
			return
		}
		#expect(terminal === h.terminals.controller(vm: "Alpine", ref: console))
		guard case .paste(let into)? = menu.perform(.pasteItems, window: .torn(torn)) else {
			Issue.record("Paste Items pasted nowhere")
			return
		}
		#expect(into == "Alpine")
	}

	// Settings, or nothing of Machman's, in front.
	@Test("W2-23: with no Machman window key the VM commands are off")
	func noWindowNoTarget() async {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Alpine")
		let shown = content(menus(h), nil, inspectorShown: nil, canPaste: true)
		#expect(!shown.run.items.contains { $0.shortcut == KeyboardShortcut("r") })
		#expect(!shown.stop.items.contains { $0.shortcut == KeyboardShortcut(".") })
		#expect(shown.file.items.filter(\.isEnabled).map(\.title) == ["New VM\u{2026}"])
		#expect(shown.edit.items.allSatisfy { !$0.isEnabled })
		#expect(shown.view.items.first { $0.action == .toggleInspector }?.isEnabled == false)
	}

	@Test("W2-24: ⌘N is New VM… and asks the main window's picker for its template page")
	func commandNIsNewVM() async throws {
		let h = await DesktopHarness.make()
		let menu = menus(h)
		let new = try #require(
			content(menu).file.items.first { $0.shortcut == KeyboardShortcut("n") })
		#expect(new.title == "New VM\u{2026}")
		#expect(new.isEnabled && new.showsMainWindow)
		#expect(!h.viewModel.newVMChooserRequested)
		_ = menu.perform(new.action, window: .torn(TornTab(vm: "Alpine", tab: .config)))
		#expect(h.viewModel.newVMChooserRequested)
	}

	@Test("W2-26: ⌘. and ⌥⌘. ask before stopping the key window's VM")
	func theStopChordsAsk() async throws {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		let menu = menus(h)
		let stop = content(menu).stop.items
		let shutDown = try #require(stop.first { $0.shortcut == KeyboardShortcut(".") })
		let force = try #require(stop.first {
			$0.shortcut == KeyboardShortcut(".", modifiers: [.option, .command])
		})
		#expect(shutDown.title == "Shut Down Debian\u{2026}" && shutDown.isEnabled)
		#expect(force.title == "Force Stop Debian\u{2026}" && force.isEnabled)
		_ = menu.perform(shutDown.action, window: .main)
		#expect(h.viewModel.pendingStop?.title == "Shut down \u{201C}Debian\u{201D}?")
		_ = menu.perform(force.action, window: .main)
		// One question at a time (Q31): the Force Stop question waits for the first.
		#expect(h.viewModel.pendingStop?.title == "Shut down \u{201C}Debian\u{201D}?")
		h.viewModel.dismissCurrentPrompt()
		#expect(await eventually {
			h.viewModel.pendingStop?.title == "Force stop \u{201C}Debian\u{201D}?"
		})
		try await Task.sleep(for: .milliseconds(50))
		#expect(!h.stub.calls.contains("stop"))
	}

	@Test("W4-24: a VM item in the View menu says it shows the VM in the main window")
	func theViewMenusVMItem() async throws {
		let h = await DesktopHarness.make()
		let menu = menus(h)
		let item = try #require(content(menu, .torn(TornTab(vm: "Alpine", tab: .config)))
			.view.items.first { $0.action == .showVM("Debian") })
		#expect(item.title == "Debian")
		#expect(item.help == "Show Debian in the main window")
		#expect(item.showsMainWindow)
		#expect(content(menu).view.items.first { $0.action == .showVM("Debian") }?
			.showsMainWindow == false)
		guard case .selected("Debian")? = menu.perform(item.action, window: nil) else {
			Issue.record("the app's selection is not told")
			return
		}
		#expect(h.viewModel.selectedName == "Debian")
	}

	@Test("15: Save as New VM… is off unless the VM runs safe")
	func saveAsNewVMNeedsASafeRun() async {
		let plain = await DesktopHarness.make()
		plain.viewModel.select(name: "Debian")
		#expect(content(menus(plain)).file.items.first { $0.action == .saveAsNewVM }?
			.isEnabled == false)
		let safe = await DesktopHarness.make([Samples.linuxSafeRun("Debian")])
		safe.viewModel.select(name: "Debian")
		let menu = menus(safe)
		#expect(content(menu).file.items.first { $0.action == .saveAsNewVM }?.isEnabled == true)
		_ = menu.perform(.saveAsNewVM, window: .main)
		#expect(safe.viewModel.safeSaveRequest?.name == "Debian")
	}

	// Decision 7: Run ▸ <VM> ▸ Start follows the start policy, like every plain Start.
	@Test("W2-12b: Run ▸ <VM> ▸ Start follows a safe headless policy")
	func runVMStartFollowsThePolicy() async throws {
		var vm = Samples.linux("Alpine")
		vm.startPolicy = StartPolicy(windowed: false, safe: true)
		let h = await DesktopHarness.make([vm])
		let menu = menus(h)
		let submenu = try #require(content(menu).run.submenus.first { $0.title == "Alpine" })
		let start = try #require(submenu.items.first { $0.title == "Start" })
		#expect(start.isEnabled)
		_ = menu.perform(start.action, window: .main)
		#expect(await eventually { h.stub.starts.count == 1 })
		#expect(h.stub.starts.first?.options == StartOptions(openWindow: false, safe: true))
	}

	@Test("W2-25: Delete VM… is off while text is edited or the VM runs")
	func deleteVMRules() async throws {
		let h = await DesktopHarness.make()
		let menu = menus(h)
		h.viewModel.select(name: "Alpine")
		#expect(await eventually { menu.facts.targets[.main]?.vm == "Alpine" })
		#expect(content(menu).file.items.first { $0.action == .deleteVM }?.isEnabled == true)
		#expect(content(menu, editingText: true).file.items.first { $0.action == .deleteVM }?
			.isEnabled == false)
		h.viewModel.select(name: "Debian")
		#expect(await eventually { menu.facts.targets[.main]?.vm == "Debian" })
		let delete = try #require(content(menu).file.items.first { $0.action == .deleteVM })
		#expect(!delete.isEnabled)
		#expect(delete.help == "Stop the VM to delete it")
	}

	@Test("P9: the menus stay put on a progress tick, a divider move and a toast")
	func theMenusStayPut() async throws {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		var canvas = h.canvases.canvas(for: "Debian")
		canvas.open(.config)
		canvas.open(.terminal(console))
		canvas.split(.terminal(console))
		h.canvases.setCanvas(canvas, for: "Debian")
		let menu = menus(h)
		try await Task.sleep(for: .milliseconds(50))
		var publishes = 0
		let watch = menu.objectWillChange.sink { publishes += 1 }
		var op = Samples.copyOperation()
		for fraction in [0.2, 0.4, 0.6] {
			op.fraction = fraction
			h.stub.emit(.operationChanged(op: op))
			#expect(await eventually { h.operations.operations.first?.fraction == fraction })
		}
		canvas.setFraction(0.3, at: 0)
		h.canvases.setCanvas(canvas, for: "Debian")
		h.viewModel.pushToast(symbol: MachmanSymbols.start, message: "Debian started")
		try await Task.sleep(for: .milliseconds(100))
		#expect(publishes == 0)
		h.viewModel.select(name: "Alpine")
		#expect(await eventually { publishes > 0 })
		watch.cancel()
	}
}

extension [MenuEntry] {
	// The items, submenus' included.
	var items: [MenuItem] {
		flatMap { entry -> [MenuItem] in
			switch entry {
			case .item(let item): return [item]
			case .submenu(_, _, let items): return items
			case .divider: return []
			}
		}
	}

	var submenus: [(title: String, items: [MenuItem])] {
		compactMap { entry in
			if case .submenu(_, let title, let items) = entry { return (title, items) }
			return nil
		}
	}
}
