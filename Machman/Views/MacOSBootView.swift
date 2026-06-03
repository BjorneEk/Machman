//
//  MacOSBootView.swift
//  Machman
//
//  macOS guest tab: install from a local .ipsw or the latest from Apple, with download/install
//  progress, plus the installed / failed / interrupted states. Failures surface inline (the
//  in-memory log is not rendered anywhere) and are also logged.
//

import SwiftUI
import UniformTypeIdentifiers

struct MacOSBootView: View {
	@ObservedObject var controller: MacInstallController

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
				controller.installLocal(url)
			}
		}
	}

	var body: some View {
		VStack {
			switch controller.phase {
			case .idle:
				installPrompt(message: nil)
			case .failed(let msg):
				installPrompt(message: msg)
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
			case .downloading(let version, let build):
				downloading(version: version, build: build)
			case .installing(let version):
				installing(version: version)
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
		.onAppear { controller.reconcile() }
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
		if controller.vmIsRunning {
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
			Button(action: { controller.installLatest() }) {
				Image(systemName: "icloud.and.arrow.down")
					.font(.title2)
			}
			.help("Download and install the latest macOS supported by this Mac")
			Spacer()
		}
		.disabled(controller.vmIsRunning)
	}

	@ViewBuilder
	private func downloading(version: String, build: String) -> some View {
		HStack {
			Text("Downloading macOS \(version) (\(build))")
				.fontWeight(.bold)
			Spacer()
			Button(action: { controller.cancel() }) {
				Image(systemName: "xmark.circle.fill")
			}
			.buttonStyle(.borderless)
			.help("Cancel the download")
		}
		if let progress = controller.downloadProgress, progress.totalUnitCount > 0 {
			ProgressView(progress)
				.progressViewStyle(.linear)
				.labelsHidden()
			TimelineView(.periodic(from: .now, by: 1)) { _ in
				HStack {
					Text(Self.byteInfo(progress, start: controller.downloadStart))
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
	private func installing(version: String) -> some View {
		HStack {
			Text("Installing macOS \(version)…")
				.fontWeight(.bold)
				.help("If an install appears stuck or fails, cancel it and retry.")
			Spacer()
			Button(action: { controller.cancel() }) {
				Image(systemName: "xmark.circle.fill")
			}
			.buttonStyle(.borderless)
			.help("Cancel the install")
		}
		if let progress = controller.installProgress {
			ProgressView(progress)
				.progressViewStyle(.linear)
				.labelsHidden()
		}
	}

	static func byteInfo(_ progress: Progress, start: Date?) -> String {
		let done = ByteCountFormatter.string(
			fromByteCount: progress.completedUnitCount, countStyle: .file)
		let total = ByteCountFormatter.string(
			fromByteCount: progress.totalUnitCount, countStyle: .file)
		var info = "\(done) of \(total)"
		let fraction = progress.fractionCompleted
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
