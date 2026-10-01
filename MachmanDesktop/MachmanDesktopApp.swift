//
//  MachmanDesktopApp.swift
//  MachmanDesktop
//
//  Created by Gustaf Franzen on 2025-03-27.
//
//  MachmanDesktop is a pure client: it renders and commands VMs that live in the MachmanAgent
//  daemon, over the socket. No Virtualization framework, no engine, no entitlements — if the
//  daemon is away, the app shows a connect screen and can launch it.
//

import SwiftUI
import MachmanUI
import Cocoa
import MachmanAPI
import MachmanDesktopCore
import MachmanDesktopUI

@main
struct MachmanDesktopApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	@StateObject var connection: DaemonConnection
	// App-scoped (survives daemon reconnects): terminal profiles + per-socket associations.
	@StateObject var profiles: TerminalProfileStore
	// The selected VM (the sidebar's selection). Serial ports open as tabs, they are not selected.
	@State var selection: String? = nil
	@StateObject private var themeStore = ThemeStore()

	init() {
		let connection = DaemonConnection()
		_connection = StateObject(wrappedValue: connection)
		AppDelegate.connection = connection   // the dock menu reads through it
		let profiles = TerminalProfileStore()
		_profiles = StateObject(wrappedValue: profiles)
		AppDelegate.profiles = profiles       // flushed on quit
	}

	private var connectedDaemonVersion: String? {
		if case .connected(let version) = connection.status { return version }
		return nil
	}

	var body: some Scene {
		WindowGroup {
			ThemedRoot(store: themeStore) {
				if let viewModel = connection.viewModel {
					VMNavigationView(
						viewModel: viewModel, selection: $selection, profiles: profiles,
						daemonVersion: connectedDaemonVersion)
						.id(ObjectIdentifier(viewModel))   // remount per (re)connection
						// A settings file set aside at launch is announced once.
						.onAppear {
							viewModel.announceSetAsideSettings([profiles, connection.canvases])
						}
				} else {
					ConnectingView(connection: connection)
				}
			}
		}
		.commands {
			CommandGroup(before: .sidebar) {
				if let viewModel = connection.viewModel {
					Button(viewModel.showInfoPanel ? "Hide Inspector" : "Show Inspector") {
						viewModel.showInfoPanel.toggle()
					}
					.keyboardShortcut("0", modifiers: [.option, .command])
					Button("Next Tab") { viewModel.cycleTab(forward: true) }
						.keyboardShortcut("]", modifiers: [.shift, .command])
					Button("Previous Tab") { viewModel.cycleTab(forward: false) }
						.keyboardShortcut("[", modifiers: [.shift, .command])
					// ⌘W closes the active canvas tab; auxiliary windows (torn tabs,
					// Settings) and tab-less states fall through to closing the window.
					// The system Close item is remapped to ⇧⌘W by the AppKit pass.
					Button("Close Tab") {
						let key = NSApp.keyWindow
						let auxiliary = key?.identifier?.rawValue
							.hasPrefix("torn-tab") == true
							|| key?.identifier?.rawValue.contains("Settings") == true
						if auxiliary || !viewModel.closeActiveTab() {
							key?.performClose(nil)
						}
					}
					.keyboardShortcut("w")
					Divider()
					ForEach(viewModel.vms) { vm in
						Button(vm.name) {
							selection = vm.name
							viewModel.select(name: vm.name)
						}
						.help("show \(vm.name)")
						// The applicable window action rides right under its VM — only for a
						// running VM with a display (P27).
						if let action = vm.windowAction {
							if action == .close {
								Button(action: {
									viewModel.closeWindow(vm.name)
								}) {
									Label("Close \(vm.name) Window",
										systemImage: MachmanSymbols.closeWindow)
								}
							} else {
								Button(action: {
									viewModel.openWindow(vm.name)
									selection = vm.name
									viewModel.select(name: vm.name)
								}) {
									Label("Open \(vm.name) Window",
										systemImage: MachmanSymbols.openWindow)
								}
							}
						}
					}
				}
			}
			CommandMenu("Run") {
				if let viewModel = connection.viewModel {
					// The selected VM's actions carry the shortcuts.
					if let vm = viewModel.selected {
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
							// A named item overrides only what it names; the rest follows the
							// policy (decision 7).
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
			}
			CommandMenu("Stop") {
				if let viewModel = connection.viewModel {
					if let vm = viewModel.selected {
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
			}
			// Entity clipboard beside the standard text Copy/Paste (Option variants so
			// text-field editing keeps plain ⌘C/⌘V).
			CommandGroup(after: .pasteboard) {
				if let viewModel = connection.viewModel {
					Divider()
					Button("Copy Items") {
						EntityClipboard.write(viewModel.copyableSelectionItems)
					}
					.keyboardShortcut("c", modifiers: [.option, .command])
					.disabled(viewModel.copyableSelectionItems.isEmpty)
					Button("Paste Items") {
						guard let vm = viewModel.selected else { return }
						AddFlows.paste(
							entities: EntityClipboard.read(),
							fileURLs: AddFlows.pasteboardFileURLs(), into: vm.name,
							viewModel: viewModel)
					}
					.keyboardShortcut("v", modifiers: [.option, .command])
					.disabled(viewModel.selected == nil
						|| (EntityClipboard.read().isEmpty
							&& AddFlows.pasteboardFileURLs().isEmpty))
				}
			}
			CommandGroup(before: CommandGroupPlacement.newItem) {
				if let viewModel = connection.viewModel {
					Button(action: {
						Task {
							if let name = await viewModel.createVM() {
								selection = name
								viewModel.select(name: name)
							}
						}
					}) {
						Label("New VM", systemImage: MachmanSymbols.add)
					}
					Button(action: {
						if let vm = viewModel.selected {
							viewModel.requestCopy(vm)
						}
					}) {
						Label("Duplicate…", systemImage: MachmanSymbols.duplicateVM)
					}
					.keyboardShortcut("d")
					.disabled(viewModel.selected == nil
						|| viewModel.selected?.refusal(.duplicateVM) != nil
						|| viewModel.copyInFlight)
					.help(viewModel.selected?.refusal(.duplicateVM) ?? "")
					Button(action: {
						if let vm = viewModel.selected { viewModel.requestSafeSave(vm) }
					}) {
						Label("Save as New VM…", systemImage: MachmanSymbols.safe)
					}
					.disabled(viewModel.selected?.safeRun != true
						|| viewModel.safeSaveInFlight)
					Button(action: {
						viewModel.saveActiveTerminalTranscript()
					}) {
						Label("Save Terminal…", systemImage: MachmanSymbols.saveToFile)
					}
					.keyboardShortcut("s")
					.disabled(viewModel.activeTerminalController == nil)
				}
			}
		}
		// Torn-off canvas tabs: one window per (vm, tab) value; Codable payload restores
		// them across relaunches. The terminal reparents from the app-scoped sessions.
		WindowGroup(id: "torn-tab", for: TornTab.self) { $payload in
			if let payload {
				ThemedRoot(store: themeStore) {
					TornTabWindowView(
						connection: connection, profiles: profiles, payload: payload)
				}
			}
		}
		.defaultSize(width: 800, height: 520)
		Settings {
			ThemedRoot(store: themeStore) {
				SettingsRootView(profiles: profiles)
			}
		}
	}
}

// Whole-class @MainActor: AppKit calls the delegate on the main thread, and the isolation
// keeps non-Sendable AppKit types (NSMenu) inside the actor instead of crossing an
// assumeIsolated boundary.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
	static weak var connection: DaemonConnection?
	static weak var profiles: TerminalProfileStore?

	// Settings writes land off the main thread, so a quit waits for the pending ones (a
	// divider dragged just before ⌘Q, a profile edit) instead of dropping them (T9).
	func applicationWillTerminate(_ notification: Notification) {
		Self.connection?.canvases.flush()
		Self.profiles?.flush()
	}

	// A pure manager: VMs live in MachmanAgent and are unaffected by this app quitting.
	nonisolated func applicationShouldTerminateAfterLastWindowClosed(
		_ sender: NSApplication
	) -> Bool {
		true
	}

	// ⌘W belongs to Close Tab (1.0.4 design); the system Close moves to ⇧⌘W. SwiftUI
	// rebuilds menus, so the remap re-runs on every activation (idempotent).
	func applicationDidFinishLaunching(_ notification: Notification) {
		DispatchQueue.main.async { Self.remapCloseShortcut() }
	}

	func applicationDidBecomeActive(_ notification: Notification) {
		Self.remapCloseShortcut()
	}

	private static func remapCloseShortcut() {
		guard let main = NSApp.mainMenu else { return }
		for top in main.items {
			guard let submenu = top.submenu else { continue }
			for item in submenu.items
				where item.action == #selector(NSWindow.performClose(_:))
					&& item.keyEquivalent == "w"
					&& item.keyEquivalentModifierMask == [.command] {
				item.keyEquivalentModifierMask = [.command, .shift]
				item.title = "Close Window"
			}
		}
	}

	// Dock menu: one start/stop toggle per VM, states at a glance. The items and their
	// enabled state come from the view model's Dock rule (dimmed while reconnecting and
	// during a macOS install).
	func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
		guard let connection = Self.connection, !connection.vmStore.vms.isEmpty else {
			return nil
		}
		let menu = NSMenu()
		menu.autoenablesItems = false
		let entries = VMListViewModel.dockMenuItems(
			vms: connection.vmStore.vms, viewModel: connection.viewModel)
		for entry in entries {
			let item = NSMenuItem(
				title: entry.title, action: #selector(toggleVM(_:)), keyEquivalent: "")
			item.target = self
			item.representedObject = entry.vm
			item.state = entry.running ? .on : .off
			item.isEnabled = entry.enabled
			menu.addItem(item)
		}
		return menu
	}

	// Through the view model, not the raw api: a start follows the VM's start policy and
	// carries the pending-start guard; failures surface as alerts.
	@objc private func toggleVM(_ sender: NSMenuItem) {
		guard let name = sender.representedObject as? String else { return }
		Self.connection?.viewModel?.performDockItem(vm: name)
	}
}
