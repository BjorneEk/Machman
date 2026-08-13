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
	}

	// The inspector is the window-level native column (VMNavigationView.inspector), so the
	// pane is just the canvas.
	private func pane(_ vm: VMInfo) -> some View {
		VMCanvasView(
			viewModel: viewModel, sessions: sessions, canvases: viewModel.canvases,
			profiles: profiles, vm: vm)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(FocusAndTopmostTracker { focused in
				viewModel.onFocusEvent(focused: focused)
			})
	}
}
