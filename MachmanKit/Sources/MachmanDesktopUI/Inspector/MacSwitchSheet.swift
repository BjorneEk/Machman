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
// copy). Irreversible and a multi-GB download, so Return presses nothing (H45, C21). A switch
// asks where to install (D32, K4): a new disk, or one of the VM's own, which it erases; a
// retry reuses its own disk without asking.
struct MacSwitchSheet: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	@Environment(\.dismiss) private var dismiss
	// The disk picked to install onto; nil = a new disk, the preselected answer.
	@State private var pick: String?

	// `pick` opens the sheet on a picked disk (render scenes, tests).
	init(viewModel: VMListViewModel, vm: VMInfo, pick: String? = nil) {
		self.viewModel = viewModel
		self.vm = vm
		_pick = State(initialValue: pick)
	}

	private var retry: Bool { vm.boot.mode == .macOS }
	private var offered: [DiskInfo] { MacInstallDisks.offered(for: vm) }
	// A picked disk gone from the VM while the sheet is open falls back to a new one.
	private var picked: DiskInfo? { offered.first { $0.id == pick } }

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
			if !offered.isEmpty {
				diskChoice
			}
			HStack {
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Spacer()
				// Stop-first, like the picker row that opens this sheet (H41).
				Button("Install from IPSW…") { installFromFile() }
					.stopFirst(vm, .installMacOS)
				Button {
					viewModel.startInstall(vm.name, source: .latest, diskID: picked?.id)
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

	// One row per answer, every disk named. A disk smaller than a new one can still be
	// picked; its row carries the warning (K15).
	private var diskChoice: some View {
		VStack(alignment: .leading, spacing: 8) {
			Picker("Install on", selection: $pick) {
				Text(MacInstallDisks.newDiskTitle).tag(String?.none)
				ForEach(offered) { disk in
					diskRow(disk).tag(String?.some(disk.id))
				}
			}
			.pickerStyle(.radioGroup)
			if let picked {
				ForEach(MacInstallDisks.notes(picked), id: \.self) { note in
					Text(note)
						.font(.callout)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	@ViewBuilder
	private func diskRow(_ disk: DiskInfo) -> some View {
		let title = MacInstallDisks.title(disk)
		if let warning = MacInstallDisks.sizeWarning(disk) {
			(Text(title + "  ")
				+ Text(Image(systemName: MachmanSymbols.warning))
					.foregroundStyle(MachmanColors.warning))
				.help(warning)
				.accessibilityLabel("\(title), \(warning)")
		} else {
			Text(title)
		}
	}

	// The New Mac flow's picker (AddFlows.chooseRestoreImage); Cancel installs nothing.
	private func installFromFile() {
		let viewModel = viewModel
		let name = vm.name
		let diskID = picked?.id
		dismiss()
		AddFlows.chooseRestoreImage { path in
			viewModel.startInstall(name, source: .ipsw(path), diskID: diskID)
		}
	}
}
