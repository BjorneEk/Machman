//
//  TornTabWindow.swift
//  MachmanDesktopUI
//
//  A canvas tab torn off into its own window (1.0.4 UI). The payload is Codable, so torn
//  windows restore across app relaunches; the terminal reparents from the app-scoped
//  TerminalSessions (the source canvas tab closes on tear-off — one mount at a time).
//  Closing the window closes the tab: the controller is torn down with it.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

// What a torn window needs from the app's connection: the current view model (nil while
// reconnecting), the app-scoped terminal sessions and VM list, and the torn-window registry.
// The app's DaemonConnection conforms and keeps the app's one registry; renders and tests
// bring their own, so no two of them share it (Q21).
@MainActor
public protocol TornTabConnection: ObservableObject {
	var viewModel: VMListViewModel? { get }
	var terminals: TerminalSessions { get }
	var vmStore: VMStore { get }
	var tornTabs: TornTabRegistry { get }
}

extension TornTabConnection {
	public var tornTabs: TornTabRegistry { .shared }
}

public struct TornTabWindowView<Connection: TornTabConnection>: View {
	@ObservedObject var connection: Connection
	@ObservedObject var profiles: TerminalProfileStore
	let payload: TornTab
	@ObservedObject private var tornTabs: TornTabRegistry
	// Observed for the title: an ssh session's rename lives here, and neither the
	// connection nor the view model forwards its changes (T13). App-scoped, so it outlives
	// reconnects.
	@ObservedObject private var terminals: TerminalSessions
	// Its VM comes from the list itself: the connection publishes only its own changes (P9).
	@ObservedObject private var store: VMStore
	@Environment(\.dismiss) private var dismiss
	@Environment(\.openWindow) private var openWindow
	@State private var showInspector: Bool

	// `inspectorShown` opens the window with its inspector showing (render scenes and tests).
	public init(
		connection: Connection, profiles: TerminalProfileStore, payload: TornTab,
		inspectorShown: Bool = false
	) {
		self.connection = connection
		self.profiles = profiles
		self.payload = payload
		_terminals = ObservedObject(wrappedValue: connection.terminals)
		_store = ObservedObject(wrappedValue: connection.vmStore)
		_tornTabs = ObservedObject(wrappedValue: connection.tornTabs)
		_showInspector = State(initialValue: inspectorShown)
	}

	public var body: some View {
		Group {
			if let viewModel = connection.viewModel,
				let vm = store.vms.first(where: { $0.name == payload.vm }) {
				content(viewModel: viewModel, vm: vm)
					// A refusal from this window's inspector shows here, not in the main window
					// (H40).
					.modifier(WindowErrorAlert(viewModel: viewModel, window: .torn(payload)))
			} else if connection.viewModel == nil {
				// Mid-reconnect: keep the window (and its controller) alive.
				ProgressView("Reconnecting…")
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				Text("\(payload.vm) is gone")
					.foregroundColor(.secondary)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.navigationTitle(payload.windowTitle(
			vms: connection.viewModel.map { _ in store.vms }, terminals: terminals))
		// The tab's own inspector rides along: the serial inspector for terminals, the VM
		// inspector for the config/preview tab. A question it asks shows in this window.
		.inspector(isPresented: $showInspector) {
			inspector
				.environment(\.tornTabWindow, payload)
				.inspectorColumnWidth(
					min: MainWindowLayout.inspector.min, ideal: MainWindowLayout.inspector.ideal,
					max: MainWindowLayout.inspector.max)
		}
		// The menu commands act on the key window (P22): this torn tab's VM and terminal,
		// and ⌥⌘0 toggles this window's inspector.
		.focusedSceneValue(\.machmanWindow, .torn(payload))
		.focusedSceneValue(\.machmanInspector, $showInspector)
		.toolbar {
			ToolbarItem(placement: .primaryAction) {
				let inspectorHelp = showInspector ? "Hide Inspector" : "Show Inspector"
				Button {
					showInspector.toggle()
				} label: {
					Image(systemName: MachmanSymbols.inspectorToggle)
				}
				.help(inspectorHelp)
				.accessibilityLabel(inspectorHelp)
			}
		}
		.onAppear {
			// Deferred: the registry is @Published; inserting mid-view-update warns. A tear-off
			// registered it already (T11); this covers a window the system restored.
			DispatchQueue.main.async {
				tornTabs.open.insert(payload)
				// A restored window can appear AFTER the last list refresh — reconcile
				// now so a payload whose VM/port is already gone gets its order at once,
				// and resolve it here in case onChange's baseline already included it.
				connection.viewModel?.reconcileTornTabs()
				resolve(tornTabs.orders[payload])
			}
		}
		.onChange(of: tornTabs.orders[payload]) { _, order in
			resolve(order)
		}
		.background(WindowCloseWatcher { windowWillClose($0) })
		// The OUTER view disappears only when the window closes (branch flips inside keep
		// it mounted) — closing the window closes the tab, tearing down its terminal (the
		// view model's one close path, which works without a view model mid-reconnect).
		// Deferred like the insert: both stores are @Published, and onDisappear runs
		// mid-view-update.
		.onDisappear { [payload, tornTabs, terminals = connection.terminals,
			viewModel = connection.viewModel] in
			DispatchQueue.main.async {
				VMListViewModel.tornWindowClosed(
					payload, registry: tornTabs, terminals: terminals, viewModel: viewModel)
			}
		}
	}

	// The user is closing this window (no order): a live SSH session docks back into the
	// canvas (C18), so the main window opens to show it. Here, before AppKit's last-window
	// check: from onDisappear the app would already have quit with the session (review F16).
	private func windowWillClose(_ window: NSWindow) {
		guard !tornTabs.closing.contains(payload),
			connection.viewModel?.docksBack(payload) == true else { return }
		// A minimized window is still open: AppKit wouldn't quit, so nothing is held (F19).
		let othersOpen = NSApp.windows.contains {
			$0 !== window && ($0.isVisible || $0.isMiniaturized) && $0.canBecomeMain
		}
		if !othersOpen { tornTabs.holdsQuitForDock = true }
		if !tornTabs.mainWindowOpen { tornTabs.reopenedMainForDock.insert(payload) }
		openWindow(id: "main")
	}

	// Act on the view model's order for this window. Consume first: acting closes the
	// window, and a lingering order must not re-fire against a future window that
	// reopens the same payload.
	private func resolve(_ order: TornTabRegistry.Order?) {
		guard let order else { return }
		tornTabs.orders[payload] = nil
		// Ordered, not closed by the user: the teardown ends the tab, never docks it (C18).
		tornTabs.closing.insert(payload)
		switch order {
		case .close:
			// The window's onDisappear is the teardown (tornWindowClosed): controller,
			// registry entry, and the tree row. closeTab posts this order for a torn tab.
			dismiss()
		case .reopen(let next):
			// The tear-off swap shape: this window's mount must be gone before the
			// successor adopts the re-keyed controller — the newest mount wins the
			// terminal. onDisappear's drop under the old key is a no-op by design.
			dismiss()
			DispatchQueue.main.async { openWindow(id: "torn-tab", value: next) }
		}
	}

	private var showsSession: Bool {
		if case .ssh = payload.tab { return true }
		return false
	}

	@ViewBuilder
	private var inspector: some View {
		if let viewModel = connection.viewModel,
			let vm = store.vms.first(where: { $0.name == payload.vm }) {
			// The main window's banner and lock (E22, H40); a session's inspector stays live.
			InspectorChrome(vm: vm, session: showsSession) {
				switch payload.tab {
				case .config:
					VMInspector(viewModel: viewModel, profiles: profiles, vm: vm)
				case .terminal(let ref):
					SerialInspector(
						vm: vm, ref: ref, viewModel: viewModel,
						sessions: connection.terminals, profiles: profiles)
				case .ssh(let ref):
					SSHSessionInspector(
						viewModel: viewModel, sessions: connection.terminals,
						profiles: profiles, vm: vm, ref: ref)
				}
			}
		} else {
			NoSelectionInspector()
		}
	}

	@ViewBuilder
	private func content(viewModel: VMListViewModel, vm: VMInfo) -> some View {
		switch payload.tab {
		case .config:
			VMPreviewTabView(vm: vm, viewModel: viewModel)
		case .terminal(let ref):
			TerminalTabContent(
				sessions: connection.terminals, profiles: profiles, vm: vm, ref: ref,
				stillWanted: { true })
		case .ssh(let ref):
			SSHTabContent(
				sessions: connection.terminals, viewModel: viewModel, profiles: profiles,
				vm: vm, ref: ref, stillWanted: { true }, adoptOnly: true)
				.modifier(TabCloseQuestion(viewModel: viewModel, window: payload))
		}
	}
}
