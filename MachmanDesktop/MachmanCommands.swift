//
//  MachmanCommands.swift
//  MachmanDesktop
//
//  The menu bar's commands. They act on the KEY window (P22): each window publishes which
//  window it is (focusedSceneValue machmanWindow) and its inspector toggle, and CommandTarget
//  resolves the VM, terminal and items the commands work on — so with a torn-off terminal in
//  front, ⌘S saves that terminal and Paste Items pastes into its VM. Commands that ask first
//  (a sheet, a dialog) bring the main window forward, where dialogs and sheets live.
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI
import MachmanDesktopCore
import MachmanDesktopUI

struct MachmanCommands: Commands {
	@ObservedObject var connection: DaemonConnection
	@Binding var selection: String?
	@FocusedValue(\.machmanWindow) private var window
	@FocusedBinding(\.machmanInspector) private var inspectorShown
	@Environment(\.openWindow) private var openWindow

	var body: some Commands {
		let target = CommandTarget(viewModel: connection.viewModel, window: keyWindow)
		CommandGroup(before: .sidebar) {
			if let viewModel = connection.viewModel {
				viewItems(viewModel, target: target)
			}
		}
		CommandMenu("Run") {
			if let viewModel = connection.viewModel {
				runItems(viewModel, target: target)
			}
		}
		CommandMenu("Stop") {
			if let viewModel = connection.viewModel {
				stopItems(viewModel, target: target)
			}
		}
		// Entity clipboard beside the standard text Copy/Paste (Option variants so
		// text-field editing keeps plain ⌘C/⌘V).
		CommandGroup(after: .pasteboard) {
			if let viewModel = connection.viewModel {
				Divider()
				Button("Copy Items") {
					EntityClipboard.write(target.copyableItems)
				}
				.keyboardShortcut("c", modifiers: [.option, .command])
				.disabled(target.copyableItems.isEmpty)
				Button("Paste Items") {
					guard let vm = target.vm else { return }
					AddFlows.paste(
						entities: EntityClipboard.read(),
						fileURLs: AddFlows.pasteboardFileURLs(), into: vm.name,
						viewModel: viewModel)
				}
				.keyboardShortcut("v", modifiers: [.option, .command])
				.disabled(target.vm == nil
					|| (EntityClipboard.read().isEmpty
						&& AddFlows.pasteboardFileURLs().isEmpty))
			}
		}
		// Replacing, not before: SwiftUI's own New Window items (the torn-tab group's too)
		// go, and ⌘N belongs to New VM.
		CommandGroup(replacing: .newItem) {
			if let viewModel = connection.viewModel {
				fileItems(viewModel, target: target)
			}
		}
	}

	// Windows say which they are through focusedSceneValue. Should a key main window not
	// have published yet, its scene id ("main") still names it; anything else stays nil.
	private var keyWindow: CommandWindow? {
		if let window { return window }
		return NSApp.keyWindow?.identifier?.rawValue.hasPrefix("main") == true ? .main : nil
	}

	// Dialogs and sheets show on the main window; bring it forward when another one is key.
	private func showMainIfNeeded(_ target: CommandTarget) {
		if target.asksOnMainWindow { openWindow(id: "main") }
	}

	// MARK: - View

	@ViewBuilder
	private func viewItems(_ viewModel: VMListViewModel, target: CommandTarget) -> some View {
		// The key window's own inspector: the main window's or a torn window's.
		Button(inspectorShown == true ? "Hide Inspector" : "Show Inspector") {
			inspectorShown?.toggle()
		}
		.keyboardShortcut("0", modifiers: [.option, .command])
		.disabled(inspectorShown == nil)
		Button("Next Tab") { viewModel.cycleTab(forward: true) }
			.keyboardShortcut("]", modifiers: [.shift, .command])
			.disabled(!target.canCycleTabs)
		Button("Previous Tab") { viewModel.cycleTab(forward: false) }
			.keyboardShortcut("[", modifiers: [.shift, .command])
			.disabled(!target.canCycleTabs)
		// ⌘W closes the main canvas's active tab; any other window (torn tabs, Settings)
		// and a tab-less canvas fall through to closing the window. The system Close item
		// is remapped to ⇧⌘W by the AppKit pass.
		Button("Close Tab") {
			if target.closesCanvasTab, viewModel.closeActiveTab() { return }
			NSApp.keyWindow?.performClose(nil)
		}
		.keyboardShortcut("w")
		Divider()
		ForEach(viewModel.vms) { vm in
			Button(vm.name) {
				// The VM shows in the main window: bring it forward from any other.
				if target.window != .main { openWindow(id: "main") }
				selection = vm.name
				viewModel.select(name: vm.name)
			}
			.help("show \(vm.name)")
			// The applicable window action rides right under its VM — only for a running
			// VM with a display (P27).
			if let action = vm.windowAction {
				if action == .close {
					Button(action: {
						viewModel.closeWindow(vm.name)
					}) {
						Label("Close \(vm.name) Window", systemImage: MachmanSymbols.closeWindow)
					}
				} else {
					Button(action: {
						viewModel.openWindow(vm.name)
						selection = vm.name
						viewModel.select(name: vm.name)
					}) {
						Label("Open \(vm.name) Window", systemImage: MachmanSymbols.openWindow)
					}
				}
			}
		}
	}

	// MARK: - Run / Stop

	@ViewBuilder
	private func runItems(_ viewModel: VMListViewModel, target: CommandTarget) -> some View {
		// The key window's VM carries the shortcuts; its title names it.
		if let vm = target.vm {
			Button("Start \(vm.name)") {
				viewModel.startPolicyDriven(vm)
			}
			.keyboardShortcut("r")
			.disabled(!viewModel.canStart(vm))
			Button("Start \(vm.name) Safe") {
				viewModel.startPolicyDriven(vm, .safe)
			}
			.keyboardShortcut("r", modifiers: [.shift, .command])
			.disabled(!viewModel.canStart(vm))
			Divider()
		}
		ForEach(viewModel.vms) { vm in
			Menu(vm.name) {
				// A named item overrides only what it names; the rest follows the policy
				// (decision 7).
				Button(action: {
					viewModel.startPolicyDriven(vm)
				}) {
					Label("Start", systemImage: MachmanSymbols.start)
				}
				.disabled(!viewModel.canStart(vm))
				Button(action: {
					viewModel.startPolicyDriven(vm, .headless)
				}) {
					Label("Start Headless", systemImage: MachmanSymbols.startHeadless)
				}
				.disabled(!viewModel.canStart(vm))
				Button(action: {
					viewModel.startPolicyDriven(vm, .safe)
				}) {
					Label("Start Safe", systemImage: MachmanSymbols.safe)
				}
				.disabled(!viewModel.canStart(vm))
			}
		}
	}

	@ViewBuilder
	private func stopItems(_ viewModel: VMListViewModel, target: CommandTarget) -> some View {
		if let vm = target.vm {
			Button("Shut Down \(vm.name)") {
				viewModel.stopVM(vm.name, mode: .soft)
			}
			.keyboardShortcut(".")
			.disabled(!vm.state.isRunning)
			Button("Force Stop \(vm.name)") {
				viewModel.stopVM(vm.name, mode: .force)
			}
			.keyboardShortcut(".", modifiers: [.option, .command])
			.disabled(!vm.state.isRunning)
			Divider()
		}
		ForEach(viewModel.vms) { vm in
			Menu(vm.name) {
				Button(action: {
					viewModel.stopVM(vm.name, mode: .soft)
				}) {
					Label("Shut Down", systemImage: MachmanSymbols.shutDown)
				}
				.disabled(!vm.state.isRunning)
				Button(action: {
					viewModel.stopVM(vm.name, mode: .force)
				}) {
					Label("Force Stop", systemImage: MachmanSymbols.forceStop)
				}
				.disabled(!vm.state.isRunning)
			}
		}
	}

	// MARK: - File

	@ViewBuilder
	private func fileItems(_ viewModel: VMListViewModel, target: CommandTarget) -> some View {
		// The toolbar picker's template page (Blank / Default / macOS) on the main window.
		Button(action: {
			openWindow(id: "main")
			viewModel.requestNewVM()
		}) {
			Label("New VM…", systemImage: MachmanSymbols.add)
		}
		.keyboardShortcut("n")
		Button(action: {
			guard let vm = target.vm else { return }
			showMainIfNeeded(target)
			viewModel.requestCopy(vm)
		}) {
			Label("Duplicate…", systemImage: MachmanSymbols.duplicateVM)
		}
		.keyboardShortcut("d")
		.disabled(target.vm == nil
			|| target.vm?.refusal(.duplicateVM) != nil
			|| viewModel.copyInFlight)
		.help(target.vm?.refusal(.duplicateVM) ?? "")
		Button(action: {
			guard let vm = target.vm else { return }
			showMainIfNeeded(target)
			viewModel.requestSafeSave(vm)
		}) {
			Label("Save as New VM…", systemImage: MachmanSymbols.safe)
		}
		.disabled(target.vm?.safeRun != true || viewModel.safeSaveInFlight)
		Button(action: {
			guard let terminal = target.terminal else { return }
			viewModel.saveTerminalTranscript(of: terminal)
		}) {
			Label("Save Terminal…", systemImage: MachmanSymbols.saveToFile)
		}
		.keyboardShortcut("s")
		.disabled(target.terminal == nil)
	}
}
