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

	init(vm: VirtualMachine) {
		self.vm = vm
		if case .macOS = vm.config.boot {
			selection = .mac
		} else {
			selection = .def
		}
	}

	private var defaultDisabled: Bool { vm.config.boot.isMacInstalled }

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
					// Placeholder; the install workflow view lands with the installer wiring.
					HStack {
						Image(systemName: "apple.logo")
							.foregroundColor(.secondary)
						Text("Install macOS")
							.foregroundColor(.secondary)
						Spacer()
					}
					.padding(4)
				}
			}
			.padding(2)
		}
		.padding(2)
		.id(vm.config.name)
		.onAppear {
			if defaultDisabled {
				selection = .mac
			}
		}
	}
}

#Preview {
}
