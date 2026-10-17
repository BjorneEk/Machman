//
//  MenuModel.swift
//  MachmanDesktopCore
//
//  The app menus' contents (Q19): every item the desktop adds to the View, Run, Stop, Edit
//  and File menus — its title, symbol, shortcut, whether it is enabled, its help and what it
//  does — decided here for the key window's target (CommandTarget's rule), so a test reads a
//  menu as the user would. MachmanCommands only renders the entries and carries out what
//  needs the app: the main window brought forward, the pasteboard, the save panel, a window
//  closed. MenuFacts is the projection of the view model the menus read, and MenuModel
//  publishes it only when it changes (P9): a progress tick, a divider move or a toast leaves
//  the menu bar alone.
//

import SwiftUI
import Combine
import MachmanAPI
import MachmanUI

// What a menu item does.
public enum MenuAction: Equatable {
	case toggleInspector
	case nextTab
	case previousTab
	case closeTab
	case showVM(String)
	case openWindow(String)
	case closeWindow(String)
	case start(String, StartIntent)
	// The Stop menu's chords ask first (P26); its per-VM items stop at once.
	case askStop(String, StopMode)
	case stop(String, StopMode)
	case copyItems
	case pasteItems
	case newVM
	case duplicate
	case saveAsNewVM
	case deleteVM
	case saveTerminal
}

public struct MenuItem: Equatable, Identifiable {
	public let id: String
	public let title: String
	public let symbol: String?
	public let shortcut: KeyboardShortcut?
	public let isEnabled: Bool
	public let help: String?
	public let action: MenuAction
	// The item asks on, or shows something in, the main window: it comes forward first.
	public let showsMainWindow: Bool

	init(
		_ id: String, _ title: String, symbol: String? = nil, shortcut: KeyboardShortcut? = nil,
		enabled: Bool = true, help: String? = nil, action: MenuAction,
		showsMainWindow: Bool = false
	) {
		self.id = id
		self.title = title
		self.symbol = symbol
		self.shortcut = shortcut
		self.isEnabled = enabled
		self.help = help
		self.action = action
		self.showsMainWindow = showsMainWindow
	}
}

public enum MenuEntry: Equatable, Identifiable {
	case item(MenuItem)
	case divider(id: String)
	case submenu(id: String, title: String, items: [MenuItem])

	public var id: String {
		switch self {
		case .item(let item): return item.id
		case .divider(let id): return id
		case .submenu(let id, _, _): return id
		}
	}
}

// What the menus read of the view model, compared before it is published.
public struct MenuFacts: Equatable {
	public struct VM: Equatable {
		public let name: String
		public let mayBeRunning: Bool
		public let canStart: Bool
		public let windowAction: VMWindowAction?
		public let safeRun: Bool
		public let duplicateRefusal: String?
		public let deleteRefusal: String?
	}

	// What a window's commands act on (CommandTarget), in the terms the menus show.
	public struct Target: Equatable {
		public let vm: String?
		public let hasTerminal: Bool
		public let canCycleTabs: Bool
		public let hasCopyableItems: Bool
		public let asksOnMainWindow: Bool
	}

	public var connected = false
	public var vms: [VM] = []
	// The main window's and every open torn window's.
	public var targets: [CommandWindow: Target] = [:]
	public var copyInFlight = false
	public var safeSaveInFlight = false

	public init() {}

	@MainActor
	public init(viewModel: VMListViewModel) {
		connected = true
		vms = viewModel.vms.map { vm in
			VM(
				name: vm.name, mayBeRunning: vm.mayBeRunning, canStart: viewModel.canStart(vm),
				windowAction: vm.windowAction, safeRun: vm.safeRun == true,
				duplicateRefusal: vm.refusal(.duplicateVM), deleteRefusal: vm.refusal(.deleteVM))
		}
		let windows = [CommandWindow.main] + viewModel.tornTabs.open.map { .torn($0) }
		for window in windows {
			let target = CommandTarget(viewModel: viewModel, window: window)
			targets[window] = Target(
				vm: target.vm?.name, hasTerminal: target.terminal != nil,
				canCycleTabs: target.canCycleTabs, hasCopyableItems: !target.copyableItems.isEmpty,
				asksOnMainWindow: target.asksOnMainWindow)
		}
		copyInFlight = viewModel.copyInFlight
		safeSaveInFlight = viewModel.safeSaveInFlight
	}
}

// The five groups of items, for the key window. Nothing while no agent is connected.
public struct MenuContent: Equatable {
	public var view: [MenuEntry] = []
	public var run: [MenuEntry] = []
	public var stop: [MenuEntry] = []
	public var edit: [MenuEntry] = []
	public var file: [MenuEntry] = []

	// `window`: the key window (nil: Settings, or none of Machman's); `inspectorShown`: its
	// inspector, nil when it has none; `canPaste`: the pasteboard holds something to paste.
	public init(
		facts: MenuFacts, window: CommandWindow?, inspectorShown: Bool?, editingText: Bool,
		canPaste: Bool
	) {
		guard facts.connected else { return }
		let target = window.flatMap { facts.targets[$0] }
		let vm = target?.vm.flatMap { name in facts.vms.first { $0.name == name } }
		let asks = target?.asksOnMainWindow ?? false
		view = Self.viewItems(facts, window, target, inspectorShown)
		run = Self.runItems(facts, vm)
		stop = Self.stopItems(facts, vm, asks)
		edit = [
			.divider(id: "edit.divider"),
			.item(MenuItem(
				"edit.copy", "Copy Items",
				shortcut: KeyboardShortcut("c", modifiers: [.option, .command]),
				enabled: target?.hasCopyableItems ?? false, action: .copyItems)),
			.item(MenuItem(
				"edit.paste", "Paste Items",
				shortcut: KeyboardShortcut("v", modifiers: [.option, .command]),
				enabled: vm != nil && canPaste, action: .pasteItems)),
		]
		file = Self.fileItems(facts, vm, target, asks, editingText)
	}

	private static func viewItems(
		_ facts: MenuFacts, _ window: CommandWindow?, _ target: MenuFacts.Target?,
		_ inspectorShown: Bool?
	) -> [MenuEntry] {
		let canCycle = target?.canCycleTabs ?? false
		var entries: [MenuEntry] = [
			// The key window's own inspector: the main window's or a torn window's.
			.item(MenuItem(
				"view.inspector", inspectorShown == true ? "Hide Inspector" : "Show Inspector",
				shortcut: KeyboardShortcut("0", modifiers: [.option, .command]),
				enabled: inspectorShown != nil, action: .toggleInspector)),
			.item(MenuItem(
				"view.next", "Next Tab",
				shortcut: KeyboardShortcut("]", modifiers: [.shift, .command]),
				enabled: canCycle, action: .nextTab)),
			.item(MenuItem(
				"view.previous", "Previous Tab",
				shortcut: KeyboardShortcut("[", modifiers: [.shift, .command]),
				enabled: canCycle, action: .previousTab)),
			// ⌘W closes the main canvas's active tab; any other window (torn tabs, Settings)
			// and a tab-less canvas fall through to closing the window.
			.item(MenuItem("view.close", "Close Tab", shortcut: KeyboardShortcut("w"),
				action: .closeTab)),
			.divider(id: "view.divider"),
		]
		for vm in facts.vms {
			// The VM shows in the main window: it comes forward from any other.
			entries.append(.item(MenuItem(
				"view.vm.\(vm.name)", vm.name, help: "Show \(vm.name) in the main window",
				action: .showVM(vm.name), showsMainWindow: window != .main)))
			// The applicable window action rides right under its VM — only for a running VM
			// with a display (P27).
			switch vm.windowAction {
			case .close?:
				entries.append(.item(MenuItem(
					"view.window.\(vm.name)", "Close \(vm.name) Window",
					symbol: MachmanSymbols.closeWindow, action: .closeWindow(vm.name))))
			case .open?:
				entries.append(.item(MenuItem(
					"view.window.\(vm.name)", "Open \(vm.name) Window",
					symbol: MachmanSymbols.openWindow, action: .openWindow(vm.name))))
			case nil:
				break
			}
		}
		return entries
	}

	private static func runItems(_ facts: MenuFacts, _ vm: MenuFacts.VM?) -> [MenuEntry] {
		var entries: [MenuEntry] = []
		// The key window's VM carries the shortcuts; its title names it.
		if let vm {
			entries += [
				.item(MenuItem(
					"run.start", "Start \(vm.name)", shortcut: KeyboardShortcut("r"),
					enabled: vm.canStart, action: .start(vm.name, .plain))),
				.item(MenuItem(
					"run.start-safe", "Start \(vm.name) Safe",
					shortcut: KeyboardShortcut("r", modifiers: [.shift, .command]),
					enabled: vm.canStart, action: .start(vm.name, .safe))),
				.divider(id: "run.divider"),
			]
		}
		// A named item overrides only what it names; the rest follows the policy (decision 7).
		for vm in facts.vms {
			let id = "run.\(vm.name)"
			entries.append(.submenu(id: id, title: vm.name, items: [
				MenuItem(
					"\(id).start", "Start", symbol: MachmanSymbols.start, enabled: vm.canStart,
					action: .start(vm.name, .plain)),
				MenuItem(
					"\(id).headless", "Start Headless", symbol: MachmanSymbols.startHeadless,
					enabled: vm.canStart, action: .start(vm.name, .headless)),
				MenuItem(
					"\(id).safe", "Start Safe", symbol: MachmanSymbols.safe,
					enabled: vm.canStart, action: .start(vm.name, .safe)),
			]))
		}
		return entries
	}

	private static func stopItems(
		_ facts: MenuFacts, _ vm: MenuFacts.VM?, _ asks: Bool
	) -> [MenuEntry] {
		var entries: [MenuEntry] = []
		// The chords ask first (P26): ⌘. is the system cancel chord, and from a focused
		// terminal it falls through to this menu. The per-VM submenus below stay immediate.
		if let vm {
			entries += [
				.item(MenuItem(
					"stop.shut-down", "Shut Down \(vm.name)\u{2026}",
					shortcut: KeyboardShortcut("."), enabled: vm.mayBeRunning,
					action: .askStop(vm.name, .soft), showsMainWindow: asks)),
				.item(MenuItem(
					"stop.force", "Force Stop \(vm.name)\u{2026}",
					shortcut: KeyboardShortcut(".", modifiers: [.option, .command]),
					enabled: vm.mayBeRunning, action: .askStop(vm.name, .force),
					showsMainWindow: asks)),
				.divider(id: "stop.divider"),
			]
		}
		for vm in facts.vms {
			let id = "stop.\(vm.name)"
			entries.append(.submenu(id: id, title: vm.name, items: [
				MenuItem(
					"\(id).shut-down", "Shut Down", symbol: MachmanSymbols.shutDown,
					enabled: vm.mayBeRunning, action: .stop(vm.name, .soft)),
				MenuItem(
					"\(id).force", "Force Stop", symbol: MachmanSymbols.forceStop,
					enabled: vm.mayBeRunning, action: .stop(vm.name, .force)),
			]))
		}
		return entries
	}

	// Replacing File ▸ New: SwiftUI's own New Window items go, and ⌘N belongs to New VM.
	private static func fileItems(
		_ facts: MenuFacts, _ vm: MenuFacts.VM?, _ target: MenuFacts.Target?, _ asks: Bool,
		_ editingText: Bool
	) -> [MenuEntry] {
		[
			// The toolbar picker's template page (Blank / Default / macOS) on the main window.
			.item(MenuItem(
				"file.new", "New VM\u{2026}", symbol: MachmanSymbols.add,
				shortcut: KeyboardShortcut("n"), action: .newVM, showsMainWindow: true)),
			.item(MenuItem(
				"file.duplicate", "Duplicate\u{2026}", symbol: MachmanSymbols.duplicateVM,
				shortcut: KeyboardShortcut("d"),
				enabled: vm != nil && vm?.duplicateRefusal == nil && !facts.copyInFlight,
				help: vm?.duplicateRefusal ?? "", action: .duplicate, showsMainWindow: asks)),
			.item(MenuItem(
				"file.save-as", "Save as New VM\u{2026}", symbol: MachmanSymbols.safe,
				enabled: vm?.safeRun == true && !facts.safeSaveInFlight, action: .saveAsNewVM,
				showsMainWindow: asks)),
			.divider(id: "file.divider.vm"),
			// Asks first ("Delete “X”?" on the main window). Off while text input is in
			// front: there ⌘⌫ deletes to the start of the line (H5).
			.item(MenuItem(
				"file.delete", "Delete VM\u{2026}", symbol: MachmanSymbols.delete,
				shortcut: KeyboardShortcut(.delete, modifiers: .command),
				enabled: vm != nil && !editingText && vm?.deleteRefusal == nil,
				help: vm?.deleteRefusal ?? "", action: .deleteVM, showsMainWindow: asks)),
			.divider(id: "file.divider.terminal"),
			.item(MenuItem(
				"file.save-terminal", "Save Terminal\u{2026}", symbol: MachmanSymbols.saveToFile,
				shortcut: KeyboardShortcut("s"), enabled: target?.hasTerminal ?? false,
				action: .saveTerminal)),
		]
	}
}

// What an item leaves for the app to do.
public enum MenuEffect {
	case toggleInspector
	case closeKeyWindow
	// The VM the main window shows now: the app keeps its own selection in step.
	case selected(String)
	case copy([EntityClipboard])
	case paste(into: String)
	case saveTerminal(any TerminalController)
}

@MainActor
public final class MenuModel: ObservableObject {
	@Published public private(set) var facts = MenuFacts()
	private weak var viewModel: VMListViewModel?
	private var sinks: [AnyCancellable] = []
	// objectWillChange fires before the change lands: read it a turn later, once for a burst.
	private lazy var recomputes = NextTurnCoalescer { [weak self] in self?.recompute() }

	public init() {}

	// The view model the menus act on: the connection's, nil while there is none.
	public func follow(_ viewModel: VMListViewModel?) {
		self.viewModel = viewModel
		sinks = []
		if let viewModel {
			let changes = [
				viewModel.objectWillChange, viewModel.canvases.objectWillChange,
				viewModel.terminals.objectWillChange, viewModel.tornTabs.objectWillChange,
			]
			sinks = changes.map { $0.sink { [weak self] in self?.recomputes.schedule() } }
		}
		recompute()
	}

	public func content(
		window: CommandWindow?, inspectorShown: Bool?, editingText: Bool, canPaste: Bool
	) -> MenuContent {
		MenuContent(
			facts: facts, window: window, inspectorShown: inspectorShown,
			editingText: editingText, canPaste: canPaste)
	}

	// Carries an item out on the view model, for the window that was key; what needs the
	// app comes back as an effect.
	public func perform(_ action: MenuAction, window: CommandWindow?) -> MenuEffect? {
		guard let viewModel else { return nil }
		let target = CommandTarget(viewModel: viewModel, window: window)
		let vm = { (name: String) in viewModel.vms.first { $0.name == name } }
		switch action {
		case .toggleInspector:
			return .toggleInspector
		case .nextTab:
			viewModel.cycleTab(forward: true)
		case .previousTab:
			viewModel.cycleTab(forward: false)
		case .closeTab:
			if target.closesCanvasTab, viewModel.closeActiveTab() { return nil }
			return .closeKeyWindow
		case .showVM(let name):
			viewModel.select(name: name)
			return .selected(name)
		case .openWindow(let name):
			viewModel.openWindow(name)
			viewModel.select(name: name)
			return .selected(name)
		case .closeWindow(let name):
			viewModel.closeWindow(name)
		case .start(let name, let intent):
			if let vm = vm(name) { viewModel.startPolicyDriven(vm, intent) }
		case .askStop(let name, let mode):
			if let vm = vm(name) { viewModel.requestStop(vm, mode: mode) }
		case .stop(let name, let mode):
			viewModel.stopVM(name, mode: mode)
		case .copyItems:
			return .copy(target.copyableItems)
		case .pasteItems:
			return target.vm.map { .paste(into: $0.name) }
		case .newVM:
			viewModel.requestNewVM()
		case .duplicate:
			if let vm = target.vm { viewModel.requestCopy(vm) }
		case .saveAsNewVM:
			if let vm = target.vm { viewModel.requestSafeSave(vm) }
		case .deleteVM:
			if let vm = target.vm { viewModel.deleteVM(vm) }
		case .saveTerminal:
			return target.terminal.map { .saveTerminal($0) }
		}
		return nil
	}

	private func recompute() {
		let next = viewModel.map(MenuFacts.init(viewModel:)) ?? MenuFacts()
		if next != facts { facts = next }
	}
}
