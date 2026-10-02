//
//  VMTabContainerView.swift
//  MachmanDesktopUI
//
//  The detail pane: the selected VM's canvas (VMCanvasView), or "Select a VM" with none
//  selected; the toolbar and the inspector column belong to VMNavigationView. Mounted once
//  and following viewModel.selected, so open terminals — held in TerminalSessions — survive
//  switching between VMs; it also pushes terminal-profile edits to every open terminal.
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

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
	}
}
