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
	// Whether text input has focus: Delete VM… (⌘⌫) is off then.
	@StateObject private var textEditing = TextEditingMonitor()

	init() {
		let profiles = TerminalProfileStore()
		_profiles = StateObject(wrappedValue: profiles)
		AppDelegate.profiles = profiles       // flushed on quit
		let connection = DaemonConnection(profiles: profiles)
		_connection = StateObject(wrappedValue: connection)
		AppDelegate.connection = connection   // the dock menu reads through it
		connection.terminals.follow(profiles)   // edits reach every open terminal, torn windows too
	}

	private var connectedDaemonVersion: String? {
		if case .connected(let version) = connection.status { return version }
		return nil
	}

	var body: some Scene {
		// ONE main window (P18): a terminal view can live in only one window (the newest
		// mount owns it — SerialTerminalView), so a second main window over the same view
		// model blanked the first one's terminals. A Window scene is single-instance, listed
		// in the Window menu, reopenable after a close, and openWindow(id: "main") brings it
		// forward.
		Window("Machman", id: "main") {
			ThemedRoot(store: themeStore) {
				if let viewModel = connection.viewModel {
					VMNavigationView(
						viewModel: viewModel, selection: $selection, profiles: profiles,
						daemonVersion: connectedDaemonVersion)
						.id(ObjectIdentifier(viewModel))   // remount per (re)connection
						// A settings file set aside at launch is announced once.
						.onAppear {
							viewModel.announceSetAsideSettings(
								[profiles, connection.canvases, viewModel.activity])
						}
				} else {
					ConnectingView(connection: connection)
				}
			}
		}
		// The window's minimum follows its content's (L1): VMNavigationView's regions while
		// connected, ConnectionStatusView's otherwise.
		.windowResizability(.contentMinSize)
		// Every menu command, aimed at the key window (MachmanCommands.swift).
		.commands {
			MachmanCommands(
				connection: connection, menu: connection.menu, textEditing: textEditing,
				selection: $selection)
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
	private var mainWindowObserver: NSObjectProtocol?

	// Settings writes land off the main thread, so a quit waits for the pending ones (a
	// divider dragged just before ⌘Q, a profile edit) instead of dropping them (T9).
	func applicationWillTerminate(_ notification: Notification) {
		Self.connection?.canvases.flush()
		Self.profiles?.flush()
		Self.connection?.operationsStore.activity.flush()
	}

	// A pure manager: VMs live in MachmanAgent and are unaffected by this app quitting. Not
	// while a torn SSH window, the last one, docks its session back and the main window is
	// reopening to show it (C18, review F16).
	nonisolated func applicationShouldTerminateAfterLastWindowClosed(
		_ sender: NSApplication
	) -> Bool {
		MainActor.assumeIsolated { !TornTabRegistry.shared.holdsQuitForDock }
	}

	// ⌘W belongs to Close Tab (1.0.4 design); the system Close moves to ⇧⌘W. SwiftUI
	// rebuilds menus, so the remap re-runs on every activation (idempotent). A window that
	// becomes main ends a dock's quit hold too: the main window it waited for is up, or
	// another window is (review F19 — the main window's appearance alone could miss it).
	func applicationDidFinishLaunching(_ notification: Notification) {
		DispatchQueue.main.async { Self.remapCloseShortcut() }
		mainWindowObserver = NotificationCenter.default.addObserver(
			forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
		) { _ in
			MainActor.assumeIsolated { TornTabRegistry.shared.holdsQuitForDock = false }
		}
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
