//
//  VMTabContainerView.swift
//  MachmanDesktop
//
//  The detail pane: a per-VM tabbed workspace. The window toolbar carries the 1.0.4 header —
//  VM indicator + picker, safe chip, window toggle, start/stop group, add popover, inspector
//  toggle (no delete: the picker's row menu owns it). Below it a tab strip switches between
//  the fixed config tab and any open serial terminals. Mounted once and following
//  viewModel.selected, so open terminals — held in TerminalSessions — survive switching
//  between VMs and hidden tabs.
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI

struct VMTabContainerView: View {
	@ObservedObject var viewModel: VMListViewModel
	@ObservedObject var sessions: TerminalSessions
	@ObservedObject var profiles: TerminalProfileStore

	var body: some View {
		Group {
			if let vm = viewModel.selected {
				pane(vm)
			} else {
				Text("Select a VM")
					.font(.title)
					.foregroundColor(.secondary)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.onReceive(profiles.objectWillChange) {
			// A profile edit pushes its live settings to every open terminal. objectWillChange
			// fires before the mutation lands, so defer a tick to read the new values.
			DispatchQueue.main.async { sessions.reapplyLiveProfiles(profiles) }
		}
		// The toolbar outlives the selection: with no VM the indicator still shows the
		// picker (the only VM switcher), while the per-VM actions disappear.
		.toolbar { toolbar(viewModel.selected) }
		// The VM indicator IS the title (1.0.4 design) — hide the app-name window title.
		.toolbar(removing: .title)
	}

	private func pane(_ vm: VMInfo) -> some View {
		HStack(spacing: 0) {
			VMCanvasView(
				viewModel: viewModel, sessions: sessions, canvases: viewModel.canvases,
				profiles: profiles, vm: vm)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			if viewModel.showInfoPanel,
				case let .terminal(ref) = viewModel.canvases.canvas(for: vm.name).activeTab {
				Divider()
				TerminalInfoPanel(
					vm: vm, ref: ref, viewModel: viewModel, sessions: sessions,
					profiles: profiles)
					.frame(width: 320)
			}
		}
		.background(FocusAndTopmostTracker { focused in
			viewModel.onFocusEvent(focused: focused)
		})
	}

	private func isTerminalActive(_ vm: VMInfo) -> Bool {
		if case .terminal = viewModel.canvases.canvas(for: vm.name).activeTab { return true }
		return false
	}

	// MARK: - Toolbar (always-active VM header)

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
			// No delete in the toolbar (1.0.4 design): it lives in the picker's row menu,
			// and the sidebar tree + VM menu grow their own entries in later stints.
			ToolbarItemGroup(placement: .primaryAction) {
				AddButton(viewModel: viewModel, vm: vm)
				Button {
					viewModel.showInfoPanel.toggle()
				} label: {
					Image(systemName: MachmanSymbols.inspectorToggle)
				}
				.disabled(!isTerminalActive(vm))
				.help(viewModel.showInfoPanel ? "Hide terminal info" : "Show terminal info")
			}
		}
	}

}
