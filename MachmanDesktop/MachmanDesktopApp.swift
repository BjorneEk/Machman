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

@main
struct MachmanDesktopApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	@StateObject var connection: DaemonConnection
	// App-scoped (survives daemon reconnects): terminal profiles + per-socket associations.
	@StateObject var profiles = TerminalProfileStore()
	// The selected VM (the sidebar's selection). Serial ports open as tabs, they are not selected.
	@State var selection: String? = nil
	@StateObject private var themeStore = ThemeStore()

	init() {
		let connection = DaemonConnection()
		_connection = StateObject(wrappedValue: connection)
		AppDelegate.connection = connection   // the dock menu reads through it
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
					Button("Close Tab") { viewModel.closeActiveTab() }
						.keyboardShortcut("w", modifiers: [.shift, .command])
					Divider()
					ForEach(viewModel.vms) { vm in
						Button(vm.name) {
							selection = vm.name
							viewModel.select(name: vm.name)
						}
						.help("show \(vm.name)")
						// The applicable window action rides right under its VM.
						if vm.state.isRunning {
							if vm.windowOpen {
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
						.disabled(vm.state.isRunning || viewModel.isInstalling(vm))
						Button("Start \(vm.name) Safe") {
							viewModel.startPolicyDriven(vm, safeOverride: true)
						}
						.keyboardShortcut("r", modifiers: [.shift, .command])
						.disabled(vm.state.isRunning || viewModel.isInstalling(vm))
						Divider()
					}
					ForEach(viewModel.vms) { vm in
						Menu(vm.name) {
							// Explicit items force their EXACT mode — window AND safety;
							// only the plain toolbar Run follows the policy checkboxes.
							Button(action: {
								viewModel.startVM(vm.name, safe: false)
							}) {
								Label("Start", systemImage: MachmanSymbols.start)
							}
							.disabled(vm.state.isRunning || viewModel.isInstalling(vm))
							Button(action: {
								viewModel.startVM(vm.name, headless: true, safe: false)
							}) {
								Label("Start Headless", systemImage: MachmanSymbols.startHeadless)
							}
							.disabled(vm.state.isRunning || viewModel.isInstalling(vm))
							Button(action: {
								viewModel.startVM(vm.name, safe: true)
							}) {
								Label("Start Safe", systemImage: MachmanSymbols.safe)
							}
							.disabled(vm.state.isRunning || viewModel.isInstalling(vm))
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
					Button("Copy Item") {
						if let entity = viewModel.copyableSelection {
							EntityClipboard.write(entity)
						}
					}
					.keyboardShortcut("c", modifiers: [.option, .command])
					.disabled(viewModel.copyableSelection == nil)
					Button("Paste Item") {
						guard let vm = viewModel.selected else { return }
						if let entity = EntityClipboard.read() {
							entity.paste(into: vm.name, viewModel: viewModel)
						} else {
							_ = AddFlows.handleFileURLs(
								AddFlows.pasteboardFileURLs(), viewModel: viewModel,
								vm: vm.name)
						}
					}
					.keyboardShortcut("v", modifiers: [.option, .command])
					.disabled(viewModel.selected == nil
						|| (EntityClipboard.read() == nil
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
						|| viewModel.selected?.state.isRunning == true
						|| viewModel.copyInFlight)
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

// The resolved theme as an observed object: recomputed on EVERY defaults write in the
// process (UserDefaults.didChangeNotification), published only when it actually changed.
// ObservableObject invalidation is unconditional — unlike App/scene-level @AppStorage,
// which does not reliably re-render scene content — so Settings edits apply instantly.
@MainActor
final class ThemeStore: ObservableObject {
	@Published private(set) var theme = MachmanTheme.fromDefaults()
	private var observer: NSObjectProtocol?

	init() {
		observer = NotificationCenter.default.addObserver(
			forName: UserDefaults.didChangeNotification, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.refresh() }
		}
	}

	private func refresh() {
		let resolved = MachmanTheme.fromDefaults()
		if resolved != theme {
			theme = resolved
		}
	}
}

// Window-level theme application: environment for MachmanUI, the color scheme, and the
// accent tint.
private struct ThemedRoot<Content: View>: View {
	@ObservedObject var store: ThemeStore
	@ViewBuilder var content: Content

	var body: some View {
		content
			.environment(\.machmanTheme, store.theme)
			.preferredColorScheme(store.theme.scheme.colorScheme)
			.tint(store.theme.accent.color)
	}
}

// Whole-class @MainActor: AppKit calls the delegate on the main thread, and the isolation
// keeps non-Sendable AppKit types (NSMenu) inside the actor instead of crossing an
// assumeIsolated boundary.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
	static weak var connection: DaemonConnection?

	// A pure manager: VMs live in MachmanAgent and are unaffected by this app quitting.
	nonisolated func applicationShouldTerminateAfterLastWindowClosed(
		_ sender: NSApplication
	) -> Bool {
		true
	}

	// Dock menu: one start/stop toggle per VM, states at a glance.
	func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
		guard let vms = Self.connection?.vmStore.vms, !vms.isEmpty else { return nil }
		let menu = NSMenu()
		for vm in vms {
			let running = vm.state.isRunning
			let item = NSMenuItem(
				title: running ? "Shut Down \(vm.name)" : "Start \(vm.name)",
				action: #selector(toggleVM(_:)), keyEquivalent: "")
			item.target = self
			item.representedObject = vm.name
			item.state = running ? .on : .off
			menu.addItem(item)
		}
		return menu
	}

	@objc private func toggleVM(_ sender: NSMenuItem) {
		guard let name = sender.representedObject as? String,
			let store = Self.connection?.vmStore,
			let api = store.api else { return }
		let running = store.vms.first { $0.name == name }?.state.isRunning == true
		Task {
			do {
				if running {
					try await api.stop(vm: name, mode: .soft)
				} else {
					try await api.start(vm: name, options: StartOptions())
				}
			} catch {
				MachmanLogger.log(.interactionError, "dock action failed: \(error)")
			}
		}
	}
}
