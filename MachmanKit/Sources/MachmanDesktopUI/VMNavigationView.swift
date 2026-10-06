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
	@Binding private var selection: String?
	// The inspector column's live width (it is resizable): the corner's toasts and cards move
	// left by it while the inspector shows (H44).
	@State private var inspectorWidth: CGFloat = 0

	public init(
		viewModel: VMListViewModel, selection: Binding<String?>,
		profiles: TerminalProfileStore, daemonVersion: String? = nil
	) {
		_viewModel = StateObject(wrappedValue: viewModel)
		self._selection = selection
		self.profiles = profiles
		self.daemonVersion = daemonVersion
	}

	public var body: some View {
		NavigationSplitView {
			// The sidebar is the SELECTED VM's device tree (1.0.4 UI); switching VMs is the
			// toolbar picker's job. `selection` (app-scoped) only mirrors the view model so
			// it survives daemon reconnects.
			Group {
				if let vm = viewModel.selected {
					VMDeviceTreeView(
						viewModel: viewModel, sessions: viewModel.terminals,
						canvases: viewModel.canvases, profiles: profiles, vm: vm)
				} else {
					VStack(spacing: 12) {
						Text(viewModel.vms.isEmpty ? "No VMs yet" : "No VM selected")
							.foregroundColor(.secondary)
						Button(action: {
							Task {
								if let name = await viewModel.createVM() {
									viewModel.select(name: name)
								}
							}
						}) {
							Label("New VM", systemImage: MachmanSymbols.add)
						}
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
			}
			// Mirror the view model's selection into the window-scoped binding (rename,
			// delete, picker) so a daemon reconnect can restore it.
			.onChange(of: viewModel.selectedName) {
				if selection != viewModel.selectedName {
					selection = viewModel.selectedName
				}
			}
			// After a daemon reconnect the view model is fresh but the window kept its
			// selection — restore it. Deferred: select() publishes mid-view-update
			// otherwise.
			.onAppear {
				guard let sel = selection, viewModel.selectedName == nil else { return }
				DispatchQueue.main.async { [weak viewModel] in
					guard let viewModel, viewModel.selectedName == nil else { return }
					viewModel.select(name: sel)
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
		// Failures show in the window key when they arrive (H40): this one or a torn one.
		.modifier(WindowErrorAlert(viewModel: viewModel, window: .main))
		.alert(
			"MAC address conflict",
			isPresented: $viewModel.isForceStartPresented,
			presenting: viewModel.pendingForceStart
		) { pending in
			Button("Start Anyway") {
				viewModel.startVM(
					pending.name, headless: pending.headless, force: true,
					safe: pending.safe)
			}
			Button("Cancel", role: .cancel) {}
		} message: { pending in
			Text(pending.message)
		}
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
		// Destructive/choice confirmations (the HIG successors to the old NSAlerts),
		// isolated in a modifier so this chain stays type-checkable.
		.modifier(ConfirmationDialogs(viewModel: viewModel))
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

// The window's confirmation dialogs, driven by the view model's pending items.
private struct ConfirmationDialogs: ViewModifier {
	@ObservedObject var viewModel: VMListViewModel

	func body(content: Content) -> some View {
		content
			.confirmationDialog(
				VMListViewModel.deleteVMTitle(viewModel.pendingVMDelete?.name ?? ""),
				isPresented: presenting($viewModel.pendingVMDelete),
				presenting: viewModel.pendingVMDelete
			) { vm in
				Button("Delete VM", role: .destructive) { viewModel.performDeleteVM(vm) }
				Button("Cancel", role: .cancel) {}
			} message: { _ in
				Text(VMListViewModel.deleteVMMessage)
			}
			// One question per drop/paste/pick, for all its files; later ones queue.
			.confirmationDialog(
				viewModel.pendingDiskAdd?.title ?? "",
				isPresented: $viewModel.isDiskAddPresented,
				presenting: viewModel.pendingDiskAdd
			) { pending in
				Button("Copy into VM") {
					AddFlows.addDiskCopies(viewModel: viewModel, pending)
				}
				Button("Reference") {
					AddFlows.addDiskReferences(viewModel: viewModel, pending)
				}
				Button("Cancel", role: .cancel) {}
			} message: { pending in
				Text(pending.message)
			}
			.confirmationDialog(
				"Delete disk "
					+ "\u{201C}\(viewModel.pendingDiskDelete?.disk.name ?? "")\u{201D}?",
				isPresented: presenting($viewModel.pendingDiskDelete),
				presenting: viewModel.pendingDiskDelete
			) { pending in
				Button("Delete Disk", role: .destructive) {
					viewModel.removeDisk(pending.vm, diskID: pending.disk.id)
				}
				Button("Cancel", role: .cancel) {}
			} message: { pending in
				Text("The backing file belongs to \(pending.vm) and is deleted with it.")
			}
			.confirmationDialog(
				"Delete \u{201C}\(viewModel.pendingKernelDelete?.fileName ?? "")\u{201D}?",
				isPresented: presenting($viewModel.pendingKernelDelete),
				presenting: viewModel.pendingKernelDelete
			) { pending in
				Button("Delete File", role: .destructive) {
					viewModel.deleteKernel(pending.vm, path: pending.path)
				}
				Button("Cancel", role: .cancel) {}
			} message: { pending in
				Text("The file belongs to \(pending.vm) and is removed from its directory.")
			}
			// Stop ▸ Shut Down… / Force Stop… (⌘. / ⌥⌘.) ask first (P26).
			.confirmationDialog(
				viewModel.pendingStop?.title ?? "",
				isPresented: presenting($viewModel.pendingStop),
				presenting: viewModel.pendingStop
			) { pending in
				Button(pending.confirmLabel, role: pending.mode == .force ? .destructive : nil) {
					viewModel.confirmStop(pending)
				}
				Button("Cancel", role: .cancel) {}
			} message: { pending in
				Text(pending.message)
			}
			// A Force Stop that can't reach a VM's vmhost asks once more before its process
			// ends (C9).
			.alert(
				viewModel.pendingEndProcess?.prompt.title ?? "",
				isPresented: $viewModel.isEndProcessPresented,
				presenting: viewModel.pendingEndProcess
			) { pending in
				Button(pending.prompt.confirm, role: .destructive) {
					viewModel.endProcess(pending.vm)
				}
				Button(pending.prompt.cancel, role: .cancel) {}
			} message: { pending in
				Text(pending.prompt.message)
			}
	}

	// isPresented bridge for item-backed confirmationDialogs (dismiss clears the item).
	private func presenting<T>(_ item: Binding<T?>) -> Binding<Bool> {
		Binding(
			get: { item.wrappedValue != nil },
			set: { if !$0 { item.wrappedValue = nil } })
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
