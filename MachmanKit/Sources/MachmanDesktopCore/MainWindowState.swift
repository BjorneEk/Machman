//
//  MainWindowState.swift
//  MachmanDesktopCore
//
//  The main window's own state, which must outlive a connection (T32): the VM it shows, the
//  tree rows selected and whether its inspector is open. The view model is made anew for
//  every connection — an agent replaced, crashed or restarted — so the app keeps this beside
//  it: VMNavigationView mirrors the view model into it and gives a fresh view model it back.
//

import Foundation

public struct MainWindowState: Equatable {
	public var selection: String?
	public var treeSelection: Set<SidebarNode> = []
	public var inspectorShown = false

	public init(selection: String? = nil) {
		self.selection = selection
	}

	// A fresh view model gets the window back: the inspector, its VM — unless a list already
	// chose one — and that VM's tree rows that still exist.
	@MainActor
	public func restore(into viewModel: VMListViewModel) {
		if inspectorShown { viewModel.showInfoPanel = true }
		if viewModel.selectedName == nil, let selection { viewModel.select(name: selection) }
		guard let vm = viewModel.selected, vm.name == selection,
			viewModel.treeSelection.isEmpty, !treeSelection.isEmpty else { return }
		viewModel.treeSelection = VMListViewModel.liveNodes(
			treeSelection, in: vm, openSessions: viewModel.openSSHSessions(vm: vm.name))
	}
}
