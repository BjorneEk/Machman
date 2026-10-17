//
//  VMTabContainerView.swift
//  MachmanDesktopUI
//
//  The detail pane: the selected VM's canvas (VMCanvasView), or "Select a VM" with none
//  selected; the toolbar and the inspector column belong to VMNavigationView. Mounted once
//  and following viewModel.selected, so open terminals — held in TerminalSessions — survive
//  switching between VMs. Profile edits reach open terminals through TerminalSessions.follow.
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
				// Nothing to select before the first VM exists (N5).
				Text(viewModel.vms.isEmpty ? "No VMs yet" : "Select a VM")
					.font(.title)
					.foregroundColor(.secondary)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
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
