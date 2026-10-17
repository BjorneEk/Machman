//
//  GuestSetupScriptRows.swift
//  MachmanDesktopUI
//
//  Guest Setup's two version rows (S67, the user's decision): Installed — what the guest's
//  last report says ran, with the run's outcome — and Serves, a menu over the host's store of
//  scripts that pins the VM, its last item importing a script file. The rules are
//  GuestSetupScripts' (DesktopCore). An older Machman Agent sends no store: Serves then reads
//  the version that Machman ships, with no menu.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct GuestSetupInstalledRow: View {
	let setup: GuestSetupInfo?

	var body: some View {
		let text = GuestSetupScripts.installed(setup)
		LabeledContent("Installed") {
			HStack(spacing: 5) {
				switch (setup?.installed == true, setup?.lastRunStatus) {
				case (false, _):
					Text(text).foregroundStyle(.secondary)
				case (true, GuestRunStatus.partial), (true, GuestRunStatus.failed):
					Image(systemName: MachmanSymbols.warning)
						.foregroundStyle(MachmanColors.warning)
					Text(text)
				default:
					Label(text, systemImage: MachmanSymbols.activeEntry)
						.foregroundStyle(MachmanColors.stateRunning)
				}
			}
		}
	}
}

struct GuestSetupServesRow: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo

	var body: some View {
		if let title = GuestSetupScripts.serves(vm.setup) {
			LabeledContent("Serves") {
				Menu {
					ForEach(GuestSetupScripts.choices(vm.setup)) { choice in
						Toggle(choice.title, isOn: Binding(
							get: { choice.isServed },
							set: { on in
								if on, !choice.isServed {
									viewModel.setSetupScript(vm.name, id: choice.id)
								}
							}))
					}
					Divider()
					Button("Use Custom Script\u{2026}") {
						Self.chooseCustomScript(viewModel: viewModel, vm: vm.name)
					}
				} label: {
					Text(title).lineLimit(1).truncationMode(.middle)
				}
				.fixedSize(horizontal: false, vertical: true)
				.help("The Guest Setup script this VM’s share serves")
			}
		} else if let current = vm.setup?.currentScriptVersion {
			LabeledContent("Serves") {
				Text("v\(current)").foregroundStyle(.secondary)
			}
		}
	}

	// Use Custom Script…: a script file picked through OpenPanels (a test answers it), which
	// joins the store and is served to this VM.
	static func chooseCustomScript(
		viewModel: VMListViewModel, vm: String, panels: OpenPanels = .system
	) {
		panels.choose(.customSetupScript(vm: vm)) { url in
			guard let url else { return }
			viewModel.useCustomSetupScript(vm, path: url.path)
		}
	}
}
