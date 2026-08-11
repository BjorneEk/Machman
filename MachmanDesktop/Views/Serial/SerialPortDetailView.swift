//
//  SerialPortDetailView.swift
//  MachmanDesktop
//
//  The detail pane for one serial port, reached from the sidebar tree. The device name sits in
//  the window toolbar; a flat tab bar spans the top with Info / Terminal / Advanced. Info is a
//  bounded two-column layout (so it can't force the window taller than the screen); Terminal is a
//  SwiftTerm attached to the port's socket via a persistent controller; Advanced is disabled
//  until the platform probe lands.
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI

struct SerialPortDetailView: View {
	let vmName: String
	let kind: SerialPortKind
	let index: Int
	@ObservedObject var viewModel: VMListViewModel
	@State private var tab: Tab = .info
	@StateObject private var terminal = SerialTerminalController()

	enum Tab: String, CaseIterable { case info = "Info", terminal = "Terminal", advanced = "Advanced" }

	private var vm: VMInfo? { viewModel.vms.first { $0.name == vmName } }
	private var port: SerialPortInfo? {
		let ports = kind == .console ? vm?.consolePorts : vm?.uartPorts
		return ports?.first { $0.index == index }
	}
	private var macGuest: Bool { vm?.boot.mode == .macOS }
	private var running: Bool { vm?.state.isRunning == true }
	private var title: String { port?.guestDevice ?? (kind == .console ? "Console" : "UART") }

	var body: some View {
		VStack(spacing: 0) {
			tabBar
			Divider()
			Group {
				switch tab {
				case .info: infoTab
				case .terminal: terminalTab
				case .advanced: advancedTab
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.toolbar {
			ToolbarItem(placement: .principal) {
				HStack(spacing: 6) {
					Image(systemName: kind == .console
						? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
						.font(.title3)
					Text(title).font(.title2).fontWeight(.semibold)
					Text("· \(vmName)").font(.title3).foregroundColor(.secondary)
				}
			}
		}
		.onAppear { connectIfPossible() }
		.onChange(of: port?.socketPath) { connectIfPossible() }
		.onChange(of: running) { connectIfPossible() }
		.onDisappear { terminal.disconnect() }
	}

	private func connectIfPossible() {
		if running, let sock = port?.socketPath { terminal.connect(path: sock) }
	}

	// MARK: - Flat tab bar

	private var tabBar: some View {
		HStack(spacing: 0) {
			ForEach(Tab.allCases, id: \.self) { t in
				Button {
					tab = t
				} label: {
					Text(t.rawValue)
						.font(.callout)
						.frame(maxWidth: .infinity)
						.padding(.vertical, 6)
						.background(tab == t ? Color.accentColor.opacity(0.18) : Color.clear)
						.foregroundColor(tab == t ? .primary : .secondary)
				}
				.buttonStyle(.plain)
				.disabled(t == .advanced)
			}
		}
	}

	// MARK: - Info

	private var infoTab: some View {
		ScrollView {
			HStack(alignment: .top, spacing: 12) {
				VStack(alignment: .leading, spacing: 10) {
					guestDeviceBox
					socketBox
				}
				.frame(maxWidth: 360)
				VStack(alignment: .leading, spacing: 10) {
					loggingBox
				}
				.frame(maxWidth: 360)
				Spacer(minLength: 0)
			}
			.padding()
		}
	}

	private var guestDeviceBox: some View {
		GroupBox("Guest device") {
			VStack(alignment: .leading, spacing: 4) {
				labeled("Linux", "/dev/" + kind.guestDevice(index: index, macGuest: false))
				if kind == .console {
					labeled("macOS", "/dev/" + kind.guestDevice(index: index, macGuest: true))
				}
				Text(setupNote).font(.caption).foregroundColor(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	private var socketBox: some View {
		GroupBox("Socket") {
			HStack {
				if let sock = port?.socketPath {
					Text(sock).font(.system(.caption, design: .monospaced))
						.lineLimit(1).truncationMode(.middle)
					CopyToClipboardButton(sock, tooltip: "Copy socket path")
				} else {
					Text("Start the VM to serve this port's socket.")
						.font(.caption).foregroundColor(.secondary)
				}
				Spacer(minLength: 0)
			}
		}
	}

	private var loggingBox: some View {
		GroupBox("Logging") {
			VStack(alignment: .leading, spacing: 6) {
				Picker("Mode", selection: modeBinding) {
					Text("Disabled").tag(SerialLogMode.disabled)
					Text("Reset on boot").tag(SerialLogMode.resetOnBoot)
					Text("Continuous").tag(SerialLogMode.continuous)
				}
				Picker("Size", selection: sizeBinding) {
					Text("Unlimited").tag(UInt64(0))
					Text("1 MB").tag(UInt64(1 << 20))
					Text("10 MB").tag(UInt64(10 << 20))
					Text("100 MB").tag(UInt64(100 << 20))
				}
				.disabled(port?.logging.mode == .disabled)
				if let logPath = port?.logPath {
					Text("Logging to \(logPath)").font(.caption).foregroundColor(.secondary)
						.lineLimit(1).truncationMode(.middle)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	private var setupNote: String {
		switch (kind, macGuest) {
		case (.console, false):
			return "Linux (systemd) starts a login on hvc\(index) automatically. Add "
				+ "console=hvc\(index) to the kernel command line to also see boot messages."
		case (.uart, false):
			return "Drivable by a bare-metal kernel, or add console=ttyAMA\(index) to a Linux "
				+ "kernel command line."
		case (.console, true):
			return "macOS runs no getty on serial by default — configure one in the guest "
				+ "(launchd) to get a login shell."
		case (.uart, true):
			return "On a macOS guest the PL011 is the kernel debug UART; it needs reduced "
				+ "security in the guest (boot-args serial=3) and has no userland device."
		}
	}

	private var modeBinding: Binding<SerialLogMode> {
		Binding(
			get: { port?.logging.mode ?? .resetOnBoot },
			set: { newMode in
				guard let current = port?.logging else { return }
				viewModel.setSerialLogging(
					vmName, kind: kind, index: index,
					config: SerialLogConfig(mode: newMode, maxBytes: current.maxBytes))
			})
	}

	private var sizeBinding: Binding<UInt64> {
		Binding(
			get: { port?.logging.maxBytes ?? 0 },
			set: { newSize in
				guard let current = port?.logging else { return }
				viewModel.setSerialLogging(
					vmName, kind: kind, index: index,
					config: SerialLogConfig(
						mode: current.mode, maxBytes: newSize == 0 ? nil : newSize))
			})
	}

	// MARK: - Terminal

	@ViewBuilder
	private var terminalTab: some View {
		if running, port?.socketPath != nil {
			VStack(spacing: 4) {
				HStack {
					if terminal.disconnected {
						Label("Disconnected", systemImage: "bolt.horizontal.circle")
							.foregroundColor(.secondary).font(.caption)
					}
					Spacer()
					Button { saveTranscript() } label: {
						Label("Save…", systemImage: MachmanSymbols.saveToFile)
					}
				}
				.padding(.horizontal, 8).padding(.top, 6)
				SerialTerminalHost(controller: terminal)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		} else {
			VStack(spacing: 8) {
				Image(systemName: kind == .console
					? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
					.font(.largeTitle).foregroundColor(.secondary)
				Text("Start the VM to open a terminal for \(title).")
					.foregroundColor(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
	}

	private func saveTranscript() {
		let panel = NSSavePanel()
		panel.nameFieldStringValue = "\(title).log"
		panel.allowedContentTypes = [.plainText]
		if panel.runModal() == .OK, let url = panel.url {
			try? terminal.transcript().write(to: url)
		}
	}

	// MARK: - Advanced (disabled until the platform probe lands)

	private var advancedTab: some View {
		VStack(spacing: 8) {
			Text("Machine-specific address info (MMIO base, IRQ)")
				.foregroundColor(.secondary)
			Text("Generating this is not available yet.")
				.font(.caption).foregroundColor(.secondary)
			Button("Generate…") {}.disabled(true)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private func labeled(_ label: String, _ value: String) -> some View {
		HStack {
			Text(label).foregroundColor(.secondary).frame(width: 52, alignment: .leading)
			Text(value).font(.system(.body, design: .monospaced))
		}
	}
}
