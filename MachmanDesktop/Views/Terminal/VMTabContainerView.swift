//
//  VMTabContainerView.swift
//  MachmanDesktop
//
//  The detail pane: a per-VM tabbed workspace. The VM's name/run/delete header is always present
//  (the window toolbar); below it a tab strip switches between the fixed config tab and any open
//  serial terminals. Mounted once and following viewModel.selected, so open terminals — held in
//  TerminalSessions — survive switching between VMs and hidden tabs.
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
		.onChange(of: viewModel.vms) { sessions.reconcile(vms: viewModel.vms) }
		.onReceive(profiles.objectWillChange) {
			// A profile edit pushes its live settings to every open terminal. objectWillChange
			// fires before the mutation lands, so defer a tick to read the new values.
			DispatchQueue.main.async { sessions.reapplyLiveProfiles(profiles) }
		}
	}

	private func pane(_ vm: VMInfo) -> some View {
		VStack(spacing: 0) {
			VMTabStrip(vm: vm, sessions: sessions)
			Divider()
			activeContent(vm)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.background(FocusAndTopmostTracker { focused in
			viewModel.onFocusEvent(focused: focused)
		})
		.toolbar { toolbar(vm) }
	}

	@ViewBuilder
	private func activeContent(_ vm: VMInfo) -> some View {
		switch sessions.state(vm.name).active {
		case .config:
			VMConfigTabView(vm: vm, viewModel: viewModel)
		case .terminal(let ref):
			terminalContent(vm: vm, ref: ref)
		}
	}

	@ViewBuilder
	private func terminalContent(vm: VMInfo, ref: SerialPortRef) -> some View {
		if let controller = sessions.controller(vm: vm.name, ref: ref) {
			SerialTerminalHost(controller: controller)
				.id(ObjectIdentifier(controller))   // swap the NSView when reloadTab replaces it
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.padding(6)
				.onChange(of: socketPath(vm: vm, ref: ref)) { _, path in
					sessions.reconnectIfPossible(vm: vm.name, ref: ref, socketPath: path)
				}
		} else {
			VStack(spacing: 8) {
				Image(systemName: ref.kind == .console
					? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
					.font(.largeTitle).foregroundColor(.secondary)
				Text("Terminal not connected.").foregroundColor(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
	}

	private func socketPath(vm: VMInfo, ref: SerialPortRef) -> String? {
		let ports = ref.kind == .console ? vm.consolePorts : vm.uartPorts
		return ports?.first(where: { $0.index == ref.index })?.socketPath
	}

	// MARK: - Toolbar (always-active VM header)

	@ToolbarContentBuilder
	private func toolbar(_ vm: VMInfo) -> some ToolbarContent {
		ToolbarItem(placement: .principal) {
			HStack {
				StatusIcon(
					state: vm.state, windowOpen: vm.windowOpen, safeRun: vm.safeRun == true)
					.font(.title2)
				EditableText($viewModel.vmName)
					.font(.largeTitle)
					.onSubmit { submitRename(vm) }
			}
		}
		ToolbarItem {
			Button {
				viewModel.toggleRun(vm)
			} label: {
				Label(
					viewModel.runBtnLbl(vm: vm).running() ? "Stop \(vm.name)" : "Run \(vm.name)",
					systemImage: viewModel.runBtnLbl(vm: vm).symbol)
			}
			.disabled(viewModel.isInstalling(vm))
			.help(runHelp(vm))
		}
		ToolbarItem {
			Button {
				viewModel.deleteVM(vm)
			} label: {
				Label("Delete", systemImage: MachmanSymbols.delete)
			}
			.help("delete \(vm.name)")
		}
	}

	private func submitRename(_ vm: VMInfo) {
		let newName = viewModel.vmName
		guard newName != vm.name else { return }
		if viewModel.hasVM(newName) {
			viewModel.present(
				message: "A VM named '\(newName)' already exists.",
				while: "Renaming \(vm.name)")
			viewModel.vmName = vm.name
			return
		}
		if VMListViewModel.confirmDialog(
			message: "Change VM name",
			informativeText: "Are you shure you want to change the name of: '\(vm.name)' to "
				+ "'\(newName)'") {
			Task {
				if await viewModel.rename(from: vm.name, to: newName) {
					viewModel.log(message: "Renamed \(vm.name) to \(newName)")
				}
			}
		} else {
			viewModel.vmName = vm.name
		}
	}

	private func runHelp(_ vm: VMInfo) -> String {
		if viewModel.isInstalling(vm) { return "macOS is installing; wait for it to finish" }
		if viewModel.runBtnLbl(vm: vm).running() { return "Stop \(vm.name)" }
		let policy = vm.startPolicy ?? StartPolicy()
		return "Run \(vm.name)" + (policy.windowed ? "" : " (headless)")
			+ (policy.safe ? " (safe)" : "")
	}
}
