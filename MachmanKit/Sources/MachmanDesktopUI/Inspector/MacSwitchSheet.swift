//
//  MacSwitchSheet.swift
//  MachmanDesktopUI
//
//  Bootloader ▸ macOS… and Install macOS…: the sheet that installs macOS on a VM.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

// The sheet that installs macOS: a switch from EFI or kernel boot that can't be undone, or
// a retry on a VM already in macOS mode (a failed or cancelled install, an unfinished Mac's
// copy). Irreversible and a multi-GB download, so Return presses nothing (H45, C21).
struct MacSwitchSheet: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	@Environment(\.dismiss) private var dismiss

	private var retry: Bool { vm.boot.mode == .macOS }

	var body: some View {
		VStack(spacing: 14) {
			Image(systemName: MachmanSymbols.bootMacTab)
				.font(.system(size: 34))
				.foregroundStyle(.secondary)
			Text(retry ? "Install macOS?" : "Switch to macOS?")
				.font(.title3.weight(.semibold))
			Text(retry
				? "Download the latest macOS, or install it from an IPSW file you have."
				: "Once macOS is installed, this VM can’t switch back to EFI or kernel boot.")
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
			HStack {
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Spacer()
				// Stop-first, like the picker row that opens this sheet (H41).
				Button("Install from IPSW…") { installFromFile() }
					.stopFirst(vm, .installMacOS)
				Button {
					viewModel.startInstall(vm.name, source: .latest)
					dismiss()
				} label: {
					Label("Download Latest", systemImage: MachmanSymbols.installDownload)
				}
				.stopFirst(vm, .installMacOS)
			}
		}
		.padding(22)
		.frame(width: 440)
	}

	// The New Mac flow's picker (AddFlows.chooseRestoreImage); Cancel installs nothing.
	private func installFromFile() {
		let viewModel = viewModel
		let name = vm.name
		dismiss()
		AddFlows.chooseRestoreImage { path in
			viewModel.startInstall(name, source: .ipsw(path))
		}
	}
}
