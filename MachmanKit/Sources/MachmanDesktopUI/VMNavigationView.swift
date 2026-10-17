//
//  VMNavigationView.swift
//  MachmanDesktopUI
//
//  Created by Gustaf Franzen on 2025-03-31.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

public struct VMNavigationView: View {
	@StateObject var viewModel: VMListViewModel
	let profiles: TerminalProfileStore
	let daemonVersion: String?
	// What the tree's Paste items read: nil is the app's watch over the general pasteboard;
	// renders pass an inert one so a scene never reads the user's pasteboard (Q21).
	private let pasteboard: PasteboardWatch?
	// The window's state that outlives this connection's view model (T32): the app keeps it.
	@Binding private var windowState: MainWindowState
	// The inspector column's live width (it is resizable): the corner's toasts and cards move
	// left by it while the inspector shows (H44).
	@State private var inspectorWidth: CGFloat = 0

	public init(
		viewModel: VMListViewModel, windowState: Binding<MainWindowState>,
		profiles: TerminalProfileStore, daemonVersion: String? = nil,
		pasteboard: PasteboardWatch? = nil
	) {
		_viewModel = StateObject(wrappedValue: viewModel)
		self._windowState = windowState
		self.profiles = profiles
		self.daemonVersion = daemonVersion
		self.pasteboard = pasteboard
	}

	public var body: some View {
		NavigationSplitView {
			// The sidebar is the SELECTED VM's device tree (1.0.4 UI); switching VMs is the
			// toolbar picker's job. `windowState` (app-scoped) only mirrors the view model so
			// it survives daemon reconnects.
			Group {
				if let vm = viewModel.selected {
					VMDeviceTreeView(
						viewModel: viewModel, sessions: viewModel.terminals,
						canvases: viewModel.canvases, profiles: profiles, vm: vm,
						pasteboard: pasteboard)
				} else {
					NoVMSidebar(viewModel: viewModel)
				}
			}
			// Mirror the view model's window state into the app-scoped binding — the VM
			// (rename, delete, picker), the tree's rows, the inspector — so a daemon
			// reconnect can restore it.
			.onChange(of: viewModel.selectedName) {
				if windowState.selection != viewModel.selectedName {
					windowState.selection = viewModel.selectedName
				}
			}
			.onChange(of: viewModel.treeSelection) {
				windowState.treeSelection = viewModel.treeSelection
			}
			.onChange(of: viewModel.showInfoPanel) {
				windowState.inspectorShown = viewModel.showInfoPanel
			}
			// After a daemon reconnect the view model is fresh but the window kept its
			// state — restore it. Deferred: select() publishes mid-view-update otherwise.
			.onAppear {
				let state = windowState
				DispatchQueue.main.async { [weak viewModel] in
					if let viewModel { state.restore(into: viewModel) }
				}
			}
			.safeAreaInset(edge: .bottom, spacing: 0) {
				daemonFooter
			}
			.navigationSplitViewColumnWidth(
				min: MainWindowLayout.sidebar.min, ideal: MainWindowLayout.sidebar.ideal,
				max: MainWindowLayout.sidebar.max)
		} detail: {
			VMTabContainerView(
				viewModel: viewModel, sessions: viewModel.terminals, profiles: profiles)
				.modifier(CanvasFloor(
					canvases: viewModel.canvases, vm: viewModel.selectedName,
					inspectorShown: viewModel.showInfoPanel))
		}
		// The NATIVE inspector column (demo design): full height beside the toolbar with
		// the system's glass treatment, not a panel embedded in the detail pane.
		.inspector(isPresented: $viewModel.showInfoPanel) {
			Group {
				if let vm = viewModel.selected {
					InspectorView(
						viewModel: viewModel, sessions: viewModel.terminals,
						profiles: profiles, vm: vm)
				} else {
					NoSelectionInspector()
				}
			}
			.onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
				inspectorWidth = $0
			}
			.inspectorColumnWidth(
				min: MainWindowLayout.inspector.min, ideal: MainWindowLayout.inspector.ideal,
				max: MainWindowLayout.inspector.max)
		}
		// The canvas's height floor, under the toolbar (L1). On the whole split view: on the
		// detail column the same 300 pt made a 456 pt window floor.
		.frame(minHeight: MainWindowLayout.canvas.height)
		// WINDOW-LEVEL toolbar (not the detail pane's): items keep one home however the
		// sidebar/inspector columns move, and the pinned background stops the bar's style
		// flipping with scroll-under content. The indicator stays with no VM selected —
		// the picker is the only VM switcher.
		.toolbar { toolbar(viewModel.selected) }
		.toolbar(removing: .title)   // the VM indicator IS the title
		.toolbarBackground(.visible, for: .windowToolbar)
		// Both spellings on purpose: the visibility API is what actually pins the bar
		// through column open/close animations (the capsule strip's clear ScrollView at the
		// top edge otherwise re-triggers the scroll-edge effect).
		.toolbarBackgroundVisibility(.visible, for: .windowToolbar)
		// Failures and the start/stop follow-up questions show in the window key when
		// they arrive (H40, K8): this one or a torn one.
		.modifier(WindowPrompts(viewModel: viewModel, window: .main))
		.sheet(item: $viewModel.copyRequest) { vm in
			CopyVMSheet(vm: vm, viewModel: viewModel)
		}
		.sheet(item: $viewModel.safeSaveRequest) { vm in
			SafeSaveSheet(vm: vm, viewModel: viewModel)
		}
		// Bottom-right feedback corner: toasts + progress cards (replaces the old
		// transfer-progress sheet — imports/promotes/copies emit operations now). The window's
		// corner, moved left past the inspector while it shows, so a card never covers its
		// last rows (H44, C7).
		.overlay {
			NotificationOverlay(viewModel: viewModel, operations: viewModel.operationsStore)
				// An offset, not padding: the corner must never weigh on the window's floor.
				.offset(x: viewModel.showInfoPanel ? -inspectorWidth : 0)
		}
		// The menu commands act on the key window (P22): this one is the main window,
		// and ⌥⌘0 toggles its inspector.
		.focusedSceneValue(\.machmanWindow, .main)
		.focusedSceneValue(\.machmanInspector, $viewModel.showInfoPanel)
		// Whether the main window is up, for a torn session docking back (F20); up again, it
		// ends the quit hold such a dock may have set (F16).
		.onAppear {
			viewModel.tornTabs.mainWindowAppeared()
			viewModel.tornTabs.holdsQuitForDock = false
		}
		.onDisappear { viewModel.tornTabs.mainWindowDisappeared() }
	}

	@ToolbarContentBuilder
	private func toolbar(_ vm: VMInfo?) -> some ToolbarContent {
		ToolbarItem(placement: .navigation) {
			VMIndicatorCluster(viewModel: viewModel, vm: vm)
		}
		// The leftmost trailing item, with or without a VM: what finished, failed or warned.
		ToolbarItem(placement: .primaryAction) {
			ActivityButton(activity: viewModel.activity)
		}
		if let vm {
			if vm.safeRun == true {
				ToolbarItem(placement: .navigation) {
					SafeModeChip()
				}
			}
			if vm.hasEnabledGraphics {
				ToolbarItem(placement: .principal) {
					WindowToggleItem(viewModel: viewModel, vm: vm)
				}
			}
			ToolbarItem(placement: .principal) {
				StartStopGroup(viewModel: viewModel, vm: vm)
			}
			// No delete in the toolbar (1.0.4 design): it lives in the picker's row menu.
			ToolbarItemGroup(placement: .primaryAction) {
				AddButton(viewModel: viewModel, vm: vm)
				let inspectorHelp = viewModel.showInfoPanel ? "Hide Inspector" : "Show Inspector"
				Button {
					viewModel.showInfoPanel.toggle()
				} label: {
					// A title for the toolbar's » menu and VoiceOver; the bar shows the icon (H33).
					Label(inspectorHelp, systemImage: MachmanSymbols.inspectorToggle)
						.labelStyle(.iconOnly)
				}
				.help(inspectorHelp)
			}
		}
	}

	// Quiet status line under the tree: the agent's version + how much is running.
	private var daemonFooter: some View {
		AgentFooter(
			version: daemonVersion, running: viewModel.vms.filter { $0.state.isRunning }.count)
	}
}

// The canvas's minimum, from which SwiftUI derives the window's floor (L1): the sidebar's
// width plus this, which follows the selected VM's open panes (three need more than one).
// While the inspector shows, SwiftUI already keeps 300 pt for the content beside it and
// would count this on top (a 900 pt window then drew 1198), so the floor is then sidebar +
// 300 + inspector and three panes share those 300 pt, each under its own minimum.
private struct CanvasFloor: ViewModifier {
	@ObservedObject var canvases: CanvasStateStore
	let vm: String?
	let inspectorShown: Bool

	func body(content: Content) -> some View {
		let panes = vm.map { canvases.canvas(for: $0).panes.count } ?? 1
		content.frame(
			minWidth: inspectorShown ? nil : MainWindowLayout.canvasMinWidth(panes: panes))
	}
}

// The sidebar while no VM is selected. New VM… opens the picker's template page, as ⌘N and
// the picker's own row do — never a Default VM made without asking (N5).
struct NoVMSidebar: View {
	@ObservedObject var viewModel: VMListViewModel

	var body: some View {
		VStack(spacing: 12) {
			Text(viewModel.vms.isEmpty ? "No VMs yet" : "No VM selected")
				.foregroundColor(.secondary)
			Button {
				viewModel.requestNewVM()
			} label: {
				Label("New VM\u{2026}", systemImage: MachmanSymbols.add)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
