//
//  VMNavigationView.swift
//  MachmanDesktop
//
//  Created by Gustaf Franzen on 2025-03-31.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct VMNavigationView: View {
	@StateObject var viewModel: VMListViewModel
	let profiles: TerminalProfileStore
	let daemonVersion: String?
	@Binding private var selection: String?

	init(
		viewModel: VMListViewModel, selection: Binding<String?>,
		profiles: TerminalProfileStore, daemonVersion: String? = nil
	) {
		_viewModel = StateObject(wrappedValue: viewModel)
		self._selection = selection
		self.profiles = profiles
		self.daemonVersion = daemonVersion
	}

	var body: some View {
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
			// selection — restore it.
			.onAppear {
				if let sel = selection, viewModel.selectedName == nil {
					viewModel.select(name: sel)
				}
			}
			.safeAreaInset(edge: .bottom, spacing: 0) {
				daemonFooter
			}
		} detail: {
			VMTabContainerView(
				viewModel: viewModel, sessions: viewModel.terminals, profiles: profiles)
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
			.inspectorColumnWidth(min: 250, ideal: 300, max: 380)
		}
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
		.alert(
			viewModel.presentedError?.title ?? "Error",
			isPresented: $viewModel.isErrorPresented,
			presenting: viewModel.presentedError
		) { _ in
			// Empty: SwiftUI supplies the default OK button.
		} message: { error in
			Text(error.message)
		}
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
		// transfer-progress sheet — imports/promotes/copies emit operations now).
		.overlay {
			NotificationOverlay(viewModel: viewModel, operations: viewModel.operationsStore)
		}
	}

	@ToolbarContentBuilder
	private func toolbar(_ vm: VMInfo?) -> some ToolbarContent {
		ToolbarItem(placement: .navigation) {
			VMIndicatorCluster(viewModel: viewModel, vm: vm)
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
				Button {
					viewModel.showInfoPanel.toggle()
				} label: {
					Image(systemName: MachmanSymbols.inspectorToggle)
				}
				.help(viewModel.showInfoPanel ? "Hide Inspector" : "Show Inspector")
			}
		}
	}

	// Quiet status line under the tree: daemon version + how much is running.
	private var daemonFooter: some View {
		let running = viewModel.vms.filter { $0.state.isRunning }.count
		return HStack(spacing: 6) {
			Circle()
				.fill(MachmanColors.stateRunning)
				.frame(width: 6, height: 6)
			Text(daemonVersion.map { "Daemon \($0)" } ?? "Daemon")
			Text("·").foregroundStyle(.tertiary)
			Text("\(running) running")
			Spacer()
		}
		.font(.caption)
		.foregroundStyle(.secondary)
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
	}
}

#Preview {
	//VMNavigationView()
}
