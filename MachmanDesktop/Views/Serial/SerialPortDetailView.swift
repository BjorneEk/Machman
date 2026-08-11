//
//  SerialPortDetailView.swift
//  MachmanDesktop
//
//  The detail pane for one serial port, reached from the sidebar tree. The device name, a
//  connect/disconnect toggle and a save button sit in the window toolbar; a small icon tab bar
//  (Info / Terminal / Advanced) spans the top-left. Info is a bounded two-column layout; Terminal
//  is a SwiftTerm attached to the port's socket via a persistent controller; Advanced is disabled
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

	enum Tab: String, CaseIterable {
		case info = "Info", terminal = "Terminal", advanced = "Advanced"
		var icon: String {
			switch self {
			case .info: return MachmanSymbols.tabInfo
			case .terminal: return MachmanSymbols.tabTerminal
			case .advanced: return MachmanSymbols.tabAdvanced
			}
		}
	}

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
			ToolbarItem {
				Button {
					if terminal.connected { terminal.disconnect() } else { connectIfPossible() }
				} label: {
					Label(
						terminal.connected ? "Disconnect" : "Connect",
						systemImage: terminal.connected
							? MachmanSymbols.serialDisconnect : MachmanSymbols.serialConnect)
				}
				.disabled(!running || port?.socketPath == nil)
				.help(terminal.connected ? "Disconnect the terminal" : "Connect the terminal")
			}
			ToolbarItem {
				Button {
					viewModel.saveActiveConsoleTranscript()
				} label: {
					Label("Save Console", systemImage: MachmanSymbols.saveToFile)
				}
				.disabled(!terminal.connected)
				.help("Save the console transcript to a file")
			}
		}
		.onAppear {
			connectIfPossible()
			viewModel.activeSerialTerminal = terminal
		}
		.onChange(of: port?.socketPath) { connectIfPossible() }
		.onChange(of: running) { connectIfPossible() }
		.onDisappear {
			terminal.disconnect()
			if viewModel.activeSerialTerminal === terminal {
				viewModel.activeSerialTerminal = nil
			}
		}
	}

	private func connectIfPossible() {
		if running, let sock = port?.socketPath { terminal.connect(path: sock) }
	}

	// MARK: - Icon tab bar (small, left, whole cell clickable)

	private var tabBar: some View {
		HStack(spacing: 2) {
			ForEach(Tab.allCases, id: \.self) { t in
				Button {
					tab = t
				} label: {
					Image(systemName: t.icon)
						.frame(width: 46, height: 26)
						.background(tab == t ? Color.accentColor.opacity(0.18) : Color.clear)
						.foregroundColor(tab == t ? .primary : .secondary)
						.clipShape(RoundedRectangle(cornerRadius: 5))
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.disabled(t == .advanced)
				.help(t.rawValue)
			}
			Spacer()
		}
		.padding(.horizontal, 6)
		.padding(.vertical, 3)
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
			// A Grid aligns the label column and the picker column, so both selectors are the
			// same width despite the different label lengths.
			Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
				GridRow {
					Text("Mode")
					Picker("", selection: modeBinding) {
						Text("Disabled").tag(SerialLogMode.disabled)
						Text("Reset on boot").tag(SerialLogMode.resetOnBoot)
						Text("Continuous").tag(SerialLogMode.continuous)
					}
					.labelsHidden()
				}
				GridRow {
					Text("Size")
					Picker("", selection: sizeBinding) {
						Text("Unlimited").tag(UInt64(0))
						Text("1 MB").tag(UInt64(1 << 20))
						Text("10 MB").tag(UInt64(10 << 20))
						Text("100 MB").tag(UInt64(100 << 20))
					}
					.labelsHidden()
					.disabled(port?.logging.mode == .disabled)
				}
			}
			if let logPath = port?.logPath {
				Text("Logging to \(logPath)").font(.caption).foregroundColor(.secondary)
					.lineLimit(1).truncationMode(.middle)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
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
			SerialTerminalHost(controller: terminal)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.padding(6)
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
