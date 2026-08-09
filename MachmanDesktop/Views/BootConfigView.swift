//
//  BootConfigView.swift
//  MachmanDesktop
//
//  Boot-mode configuration pane: a default (EFI / Linux-kernel) tab and a macOS guest tab.
//  Once a VM has macOS installed its boot mode is locked, so the default tab is disabled.
//  Install phases arrive as DTO snapshots through the view model's event feed.
//

import SwiftUI
import MachmanAPI

struct BootConfigView: View {
	let vm: VMInfo
	@ObservedObject var viewModel: VMListViewModel
	@State private var selection: BootTab

	init(vm: VMInfo, viewModel: VMListViewModel) {
		self.vm = vm
		self.viewModel = viewModel
		_selection = State(initialValue: vm.boot.mode == .macOS ? .mac : .def)
	}

	private var phase: InstallPhase { viewModel.installPhase(for: vm) }

	private var defaultDisabled: Bool {
		vm.boot.macInstalled || phase.kind == .installed
	}

	var body: some View {
		GroupBox {
			VStack {
				BootTabStrip(
					selection: $selection,
					defaultDisabled: defaultDisabled,
					defaultDisabledHelp: "This VM has macOS installed; its boot mode is locked.")
				switch selection {
				case .def:
					DefaultBootView(vm: vm, viewModel: viewModel)
				case .mac:
					MacOSBootView(vm: vm, viewModel: viewModel)
				}
			}
			.padding(2)
		}
		.padding(2)
		.onAppear {
			if defaultDisabled {
				selection = .mac
			}
		}
		.onChange(of: phase) { _, newPhase in
			if newPhase.kind == .installed {
				selection = .mac
			}
		}
	}
}

#Preview {
}
