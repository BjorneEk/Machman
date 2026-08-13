//
//  VMPreviewTabView.swift
//  MachmanDesktop
//
//  The VM tab's content (1.0.4 UI): the live preview with a status caption — configuration
//  moved wholly into the inspectors, so this tab is the machine's face, not a settings
//  page. Headless VMs get the add-a-display hint; a running macOS install shows its phase
//  banner here (the corner progress cards arrive with S7).
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct VMPreviewTabView: View {
	let vm: VMInfo
	@ObservedObject var viewModel: VMListViewModel

	var body: some View {
		VStack(spacing: 10) {
			installBanner
			if vm.hasEnabledGraphics {
				PreviewView(viewModel: viewModel, previews: viewModel.previewImages)
					.frame(maxWidth: 720)
					.padding(.horizontal, 24)
				caption
			} else {
				noDisplayPlaceholder
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding(.vertical, 16)
	}

	private var caption: some View {
		HStack(spacing: 6) {
			StatusDot(state: vm.state, size: 7)
			Text(String(describing: vm.state))
				.font(.callout)
				.foregroundStyle(.secondary)
			if vm.safeRun == true { SafeBadge(compact: true) }
			Text("·").foregroundStyle(.tertiary)
			BootBadge(mode: vm.boot.mode, size: 10)
		}
	}

	private var noDisplayPlaceholder: some View {
		VStack(spacing: 10) {
			Image(systemName: MachmanSymbols.deviceGraphics)
				.font(.system(size: 34, weight: .light))
				.foregroundStyle(.tertiary)
			Text("No display device")
				.font(.title3)
				.foregroundStyle(.secondary)
			Text("This VM is headless — add a display to enable the window and preview.")
				.font(.callout)
				.foregroundStyle(.tertiary)
			Button {
				viewModel.addDevice(vm.name, kind: .graphics)
			} label: {
				Label("Add Display", systemImage: MachmanSymbols.deviceGraphics)
			}
			.buttonStyle(MachmanButtonStyle())
			.padding(.top, 4)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	// The macOS install's live phase, shown by the machine it concerns. Failure and
	// interruption surface here too; a fresh attempt starts from the VM inspector's
	// boot section.
	@ViewBuilder
	private var installBanner: some View {
		let phase = viewModel.installPhase(for: vm)
		switch phase.kind {
		case .resolving, .downloading, .installing:
			VStack(spacing: 6) {
				HStack(spacing: 6) {
					ProgressView().controlSize(.small)
					Text(phaseLabel(phase))
						.font(.callout)
					Spacer()
					Button("Cancel") { viewModel.cancelInstall(vm.name) }
						.controlSize(.small)
				}
				if let progress = phase.progress {
					ProgressView(value: progress.fraction)
						.controlSize(.small)
				}
			}
			.padding(10)
			.machmanGlass(cornerRadius: 8)
			.frame(maxWidth: 480)
		case .failed:
			Label(phase.message ?? "The macOS install failed",
				systemImage: MachmanSymbols.warning)
				.font(.callout)
				.foregroundStyle(MachmanColors.warning)
		case .interrupted:
			Label("The macOS install was interrupted — restart it from the VM's "
				+ "boot settings", systemImage: MachmanSymbols.warning)
				.font(.callout)
				.foregroundStyle(MachmanColors.warning)
		case .idle, .installed:
			EmptyView()
		}
	}

	private func phaseLabel(_ phase: InstallPhase) -> String {
		let version = phase.version.map { " macOS \($0)" } ?? ""
		switch phase.kind {
		case .resolving: return "Resolving\(version)…"
		case .downloading: return "Downloading\(version)…"
		default: return "Installing\(version)…"
		}
	}
}
