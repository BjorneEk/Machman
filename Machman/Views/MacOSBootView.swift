//
//  MacOSBootView.swift
//  Machman
//
//  macOS guest tab: install from a local .ipsw or the latest from Apple, with download/install
//  progress, plus the installed / failed / interrupted states. Renders InstallPhase snapshots
//  from the event feed; actions go through the API.
//

import SwiftUI
import UniformTypeIdentifiers
import MachmanAPI

struct MacOSBootView: View {
	let vm: VMInfo
	@ObservedObject var viewModel: VMListViewModel

	private var phase: InstallPhase { viewModel.installPhase(for: vm) }

	private func pickIPSW() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		if let ipsw = UTType(filenameExtension: "ipsw") {
			panel.allowedContentTypes = [ipsw]
		}
		panel.begin { response in
			if response == .OK, let url = panel.url {
				viewModel.startInstall(vm.name, source: .ipsw(url.path))
			}
		}
	}

	var body: some View {
		VStack {
			switch phase.kind {
			case .idle:
				installPrompt(message: nil)
			case .failed:
				installPrompt(message: phase.message ?? "install failed")
			case .interrupted:
				installPrompt(message: "A previous install was interrupted; you can start over.")
			case .resolving:
				HStack {
					ProgressView()
						.controlSize(.small)
					Text("Preparing…")
						.foregroundColor(.secondary)
					Spacer()
				}
			case .downloading:
				downloading(
					version: phase.version ?? "macOS", build: phase.build ?? "",
					progress: phase.progress, start: phase.downloadStartedAt)
			case .installing:
				installing(version: phase.version ?? "macOS", progress: phase.progress)
			case .installed:
				HStack {
					Image(systemName: "apple.logo")
					Text("macOS Installed")
						.fontWeight(.bold)
					Spacer()
				}
			}
		}
		.padding(4)
	}

	@ViewBuilder
	private func installPrompt(message: String?) -> some View {
		HStack {
			Text("Install macOS")
				.fontWeight(.bold)
			Spacer()
		}
		if let message = message {
			HStack {
				Text(message)
					.foregroundColor(.red)
					.opacity(0.8)
					.textSelection(.enabled)
				Spacer()
			}
		}
		Divider()
		if vm.state.isRunning {
			HStack {
				Text("Stop the VM before installing macOS")
					.foregroundColor(.secondary)
				Spacer()
			}
		}
		HStack {
			Button(action: { pickIPSW() }) {
				Image(systemName: "folder.fill.badge.plus")
					.font(.title2)
			}
			.help("Install from a local .ipsw restore image")
			Button(action: { viewModel.startInstall(vm.name, source: .latest) }) {
				Image(systemName: "icloud.and.arrow.down")
					.font(.title2)
			}
			.help("Download and install the newest macOS this host can install")
			Spacer()
		}
		.disabled(vm.state.isRunning)
	}

	@ViewBuilder
	private func downloading(
		version: String, build: String, progress: ProgressInfo?, start: Date?
	) -> some View {
		HStack {
			Text("Downloading macOS \(version) (\(build))")
				.fontWeight(.bold)
			Spacer()
			Button(action: { viewModel.cancelInstall(vm.name) }) {
				Image(systemName: "xmark.circle.fill")
			}
			.buttonStyle(.borderless)
			.help("Cancel the download")
		}
		if let progress = progress, (progress.totalBytes ?? 0) > 0 {
			ProgressView(value: progress.fraction)
				.progressViewStyle(.linear)
				.labelsHidden()
			TimelineView(.periodic(from: .now, by: 1)) { _ in
				HStack {
					Text(Self.byteInfo(progress, start: start))
						.font(.caption)
						.foregroundColor(.secondary)
					Spacer()
				}
			}
		} else {
			HStack {
				ProgressView()
					.controlSize(.small)
				Spacer()
			}
		}
	}

	@ViewBuilder
	private func installing(version: String, progress: ProgressInfo?) -> some View {
		HStack {
			Text("Installing macOS \(version)…")
				.fontWeight(.bold)
				.help("If an install appears stuck or fails, cancel it and retry.")
			Spacer()
			Button(action: { viewModel.cancelInstall(vm.name) }) {
				Image(systemName: "xmark.circle.fill")
			}
			.buttonStyle(.borderless)
			.help("Cancel the install")
		}
		if let progress = progress {
			ProgressView(value: progress.fraction)
				.progressViewStyle(.linear)
				.labelsHidden()
		}
	}

	static func byteInfo(_ progress: ProgressInfo, start: Date?) -> String {
		let done = ByteCountFormatter.string(
			fromByteCount: progress.completedBytes ?? 0, countStyle: .file)
		let total = ByteCountFormatter.string(
			fromByteCount: progress.totalBytes ?? 0, countStyle: .file)
		var info = "\(done) of \(total)"
		let fraction = progress.fraction
		if let start = start, fraction > 0.01 {
			let elapsed = Date().timeIntervalSince(start)
			if elapsed > 5 {
				info += " — about \(timeString(elapsed * (1 - fraction) / fraction)) left"
			}
		}
		return info
	}

	static func timeString(_ t: TimeInterval) -> String {
		if t < 60 { return "\(Int(t))s" }
		if t < 3600 { return "\(Int(t / 60))m" }
		return String(format: "%.1fh", t / 3600)
	}
}

#Preview {
}
