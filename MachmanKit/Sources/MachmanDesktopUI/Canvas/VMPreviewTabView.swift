//
//  VMPreviewTabView.swift
//  MachmanDesktopUI
//
//  The VM tab's content (1.0.4 UI, demo design): a centered rounded display block — live
//  preview frames while running, spinner during transitions, a big start button while
//  stopped — with the safe-run stroke + badge, and the status caption underneath.
//  Configuration lives wholly in the inspectors. Headless VMs get the add-a-display hint;
//  a running macOS install shows its phase banner here (corner cards arrive with S7).
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct VMPreviewTabView: View {
	let vm: VMInfo
	@ObservedObject var viewModel: VMListViewModel
	// Re-render on each preview frame without churning the whole canvas.
	@ObservedObject private var previews: PreviewStore
	@Environment(\.machmanTheme) private var theme

	init(vm: VMInfo, viewModel: VMListViewModel) {
		self.vm = vm
		self.viewModel = viewModel
		self.previews = viewModel.previewImages
	}

	var body: some View {
		Group {
			if vm.hasEnabledGraphics {
				VStack(spacing: 10) {
					installBanner
					displayBlock
						.aspectRatio(16.0 / 10.0, contentMode: .fit)
						.frame(maxWidth: 720)
						.padding(.horizontal, 24)
					caption
				}
			} else {
				VStack(spacing: 10) {
					installBanner
					noDisplayPlaceholder
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding(.vertical, 16)
	}

	// MARK: - Display block (demo design)

	private var displayBlock: some View {
		let shape = RoundedRectangle(cornerRadius: theme.metrics.radiusL, style: .continuous)
		return ZStack {
			Color.black
			switch vm.state {
			case .running, .paused:
				if let image = previews.images[vm.name] {
					Image(nsImage: image)
						.resizable()
						.scaledToFit()
				} else {
					VStack(spacing: 10) {
						ProgressView().controlSize(.regular).tint(.white)
						Text("Waiting for the first frame…")
							.font(.callout).foregroundStyle(.gray)
					}
				}
			case .starting:
				VStack(spacing: 10) {
					ProgressView().controlSize(.regular).tint(.white)
					Text("Starting…").font(.callout).foregroundStyle(.gray)
				}
			case .stopping:
				VStack(spacing: 10) {
					ProgressView().controlSize(.regular).tint(.white)
					Text("Shutting down…").font(.callout).foregroundStyle(.gray)
				}
			case .stopped, .error, .unknown:
				VStack(spacing: 12) {
					Button {
						viewModel.startPolicyDriven(vm)
					} label: {
						Image(systemName: MachmanSymbols.start)
							.font(.system(size: 34, weight: .bold))
							.foregroundStyle(.white)
							.padding(22)
							.background(Circle().fill(.white.opacity(0.14)))
					}
					.buttonStyle(.plain)
					.machmanHoverable(radius: 40, scales: true)
					.disabled(viewModel.isInstalling(vm))
					.help("Start \(vm.name)")
					Text("VM is stopped").font(.callout).foregroundStyle(.gray)
				}
			}
		}
		.clipShape(shape)
		.overlay {
			shape.strokeBorder(
				vm.safeRun == true
					? MachmanColors.safeMode.opacity(0.8) : Color.white.opacity(0.12),
				lineWidth: vm.safeRun == true ? 2 : 1)
		}
		.overlay(alignment: .bottomTrailing) {
			if vm.safeRun == true {
				HStack(spacing: 4) {
					SafeBadge(compact: true)
					Text("Safe run")
						.font(.system(size: 10, weight: .semibold))
						.foregroundStyle(MachmanColors.safeMode)
				}
				.padding(.horizontal, 8)
				.padding(.vertical, 4)
				.background(Capsule().fill(.black.opacity(0.5)))
				.padding(10)
			}
		}
		.shadow(color: .black.opacity(0.35), radius: 16, y: 8)
	}

	private var caption: some View {
		HStack(spacing: 6) {
			VMStatusDot(vm: vm, size: 7)
			Text(vm.stateLabel)
				.font(.callout)
				.foregroundStyle(.secondary)
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
			installProblem(phase.message ?? "The macOS install failed")
		case .interrupted:
			installProblem("The macOS install was interrupted — restart it from the VM's "
				+ "boot settings")
		case .idle, .installed:
			EmptyView()
		}
	}

	// An install that ended badly. The engine's reason is a whole error description (VZ's
	// run to ~70 characters and more): two lines at most, kept off the canvas edges, the full
	// text in the tooltip.
	private func installProblem(_ message: String) -> some View {
		Label(message, systemImage: MachmanSymbols.warning)
			.font(.callout)
			.foregroundStyle(MachmanColors.warning)
			.lineLimit(2)
			.truncationMode(.tail)
			.frame(maxWidth: 480)
			.padding(.horizontal, 24)
			.help(message)
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
