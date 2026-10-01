//
//  WindowCommands.swift
//  MachmanDesktopCore
//
//  What the menu bar's commands act on (P22): the KEY window's VM, terminal and selection,
//  torn-off windows included — not always the main window's. Each window publishes which
//  window it is through a focused scene value (VMNavigationView: .main; a torn window: its
//  payload); the app's Commands read the key window's value and resolve it here, in a
//  headless, testable value.
//

import SwiftUI
import MachmanAPI
import MachmanUI

// Which Machman window is key, as far as menu commands care.
public enum CommandWindow: Hashable {
	case main
	case torn(TornTab)
}

private struct CommandWindowKey: FocusedValueKey {
	typealias Value = CommandWindow
}

// The key window's inspector toggle (⌥⌘0 shows or hides the inspector of the window in front).
private struct InspectorShownKey: FocusedValueKey {
	typealias Value = Binding<Bool>
}

extension FocusedValues {
	public var machmanWindow: CommandWindow? {
		get { self[CommandWindowKey.self] }
		set { self[CommandWindowKey.self] = newValue }
	}

	public var machmanInspector: Binding<Bool>? {
		get { self[InspectorShownKey.self] }
		set { self[InspectorShownKey.self] = newValue }
	}
}

// The targets of the VM, terminal and item commands for the key window. With no Machman
// window key (Settings, nothing) or no connection, there is nothing to act on.
@MainActor
public struct CommandTarget {
	public let window: CommandWindow?
	// The VM the window shows — the main window's selection, a torn window's own VM.
	public let vm: VMInfo?
	// The terminal Save Terminal… saves: the main canvas's active terminal tab, or the torn
	// window's terminal. nil on a configuration tab and on a restored, ended session.
	public let terminal: (any TerminalController)?
	// Next/Previous Tab cycle the main canvas's active pane; a torn window has one tab.
	public let canCycleTabs: Bool
	// Copy Items copies the main tree's selection; a torn window has no tree.
	public let copyableItems: [EntityClipboard]
	// Dialogs and sheets live on the main window: a command that asks first brings it
	// forward when another window is key.
	public let asksOnMainWindow: Bool

	// ⌘W closes the main canvas's active tab; any other window closes as a whole.
	public var closesCanvasTab: Bool { window == .main }

	public init(viewModel: VMListViewModel?, window: CommandWindow?) {
		self.window = window
		switch (viewModel, window) {
		case (let viewModel?, .main?):
			vm = viewModel.selected
			terminal = viewModel.activeTerminalController
			canCycleTabs = viewModel.canCycleTabs
			copyableItems = viewModel.copyableSelectionItems
			asksOnMainWindow = false
		case (let viewModel?, .torn(let torn)?):
			vm = viewModel.vms.first { $0.name == torn.vm }
			terminal = viewModel.terminals.controller(for: torn.tab, vm: torn.vm)
			canCycleTabs = false
			copyableItems = []
			asksOnMainWindow = true
		default:
			vm = nil
			terminal = nil
			canCycleTabs = false
			copyableItems = []
			asksOnMainWindow = false
		}
	}
}
