//
//  BootConfigView.swift
//  Machman
//
//  Boot-mode configuration pane: a default (EFI / Linux-kernel) tab and a macOS guest tab.
//  Once a VM has macOS installed its boot mode is locked, so the default tab is disabled.
//

import SwiftUI

struct BootConfigView: View {
	@State private var vm: VirtualMachine
	@State private var selection: BootTab
	@StateObject private var installController: MacInstallController

	init(vm: VirtualMachine, viewModel: VMListViewModel? = nil) {
		self.vm = vm
		if case .macOS = vm.config.boot {
			selection = .mac
		} else {
			selection = .def
		}
		_installController = StateObject(
			wrappedValue: MacInstallController(vm: vm, listViewModel: viewModel))
	}

	private var defaultDisabled: Bool {
		vm.config.boot.isMacInstalled || installController.phase == .installed
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
					DefaultBootView(vm: vm)
				case .mac:
					MacOSBootView(controller: installController)
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
		.onChange(of: installController.phase) { _, newPhase in
			if newPhase == .installed {
				selection = .mac
			}
		}
	}
}

#Preview {
}
