//
//  SerialPortDetailView.swift
//  MachmanDesktop
//
//  The detail pane for one serial port, reached from the sidebar tree. Three tabs: Info (guest
//  device names, setup notes, socket path, logging config), Terminal (a SwiftTerm attached to
//  the port's socket), and Advanced (mmio/irq — disabled until the platform probe lands).
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MachmanUI
import MachmanAPI

struct SerialPortDetailView: View {
	let vmName: String
	let kind: SerialPortKind
	let index: Int
	@ObservedObject var viewModel: VMListViewModel
	@State private var tab: Tab = .info

	enum Tab: String, CaseIterable { case info = "Info", terminal = "Terminal", advanced = "Advanced" }

	private var vm: VMInfo? {
		viewModel.vms.first { $0.name == vmName }
	}
	private var port: SerialPortInfo? {
		let ports = kind == .console ? vm?.consolePorts : vm?.uartPorts
		return ports?.first { $0.index == index }
	}
	private var macGuest: Bool { vm?.boot.mode == .macOS }
	private var running: Bool { vm?.state.isRunning == true }

	var body: some View {
		if let port = port {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					Image(systemName: kind == .console
						? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
						.font(.title)
					VStack(alignment: .leading) {
						Text(port.guestDevice).font(.title2).fontWeight(.bold)
						Text("\(kind == .console ? "Console" : "UART") port on \(vmName)")
							.font(.caption).foregroundColor(.secondary)
					}
					Spacer()
				}
				Picker("", selection: $tab) {
					ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
				}
				.pickerStyle(.segmented)
				.labelsHidden()
				Divider()
				switch tab {
				case .info: infoTab(port)
				case .terminal: terminalTab(port)
				case .advanced: advancedTab
				}
				Spacer()
			}
			.padding()
		} else {
			Text("This serial port is no longer configured.")
				.foregroundColor(.secondary)
		}
	}

	// MARK: - Info

	@ViewBuilder
	private func infoTab(_ port: SerialPortInfo) -> some View {
		VStack(alignment: .leading, spacing: 10) {
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
			GroupBox("Socket") {
				HStack {
					if let sock = port.socketPath {
						Text(sock).font(.system(.caption, design: .monospaced)).lineLimit(1)
							.truncationMode(.middle)
						CopyToClipboardButton(sock, tooltip: "Copy socket path")
					} else {
						Text("Start the VM to serve this port's socket.")
							.foregroundColor(.secondary)
					}
					Spacer()
				}
			}
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
					.disabled(port.logging.mode == .disabled)
					if let logPath = port.logPath {
						Text("Logging to \(logPath)").font(.caption).foregroundColor(.secondary)
							.lineLimit(1).truncationMode(.middle)
					}
				}
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
					config: SerialLogConfig(mode: current.mode, maxBytes: newSize == 0 ? nil : newSize))
			})
	}

	// MARK: - Terminal

	@ViewBuilder
	private func terminalTab(_ port: SerialPortInfo) -> some View {
		if running, let sock = port.socketPath {
			SerialTerminalPane(socketPath: sock)
		} else {
			VStack(spacing: 8) {
				Image(systemName: kind == .console
					? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
					.font(.largeTitle).foregroundColor(.secondary)
				Text("Start the VM to open a terminal for \(port.guestDevice).")
					.foregroundColor(.secondary)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
	}

	// MARK: - Advanced (disabled until the platform probe lands)

	@ViewBuilder
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
			Text(label).foregroundColor(.secondary).frame(width: 60, alignment: .leading)
			Text(value).font(.system(.body, design: .monospaced))
		}
	}
}

// The terminal pane owns the socket connection for its lifetime, and can save the transcript.
struct SerialTerminalPane: View {
	let socketPath: String
	@State private var connection: SerialTerminalConnection?
	@State private var disconnected = false

	var body: some View {
		VStack(spacing: 4) {
			HStack {
				if disconnected {
					Label("Disconnected", systemImage: "bolt.horizontal.circle")
						.foregroundColor(.secondary).font(.caption)
				}
				Spacer()
				Button {
					save()
				} label: {
					Label("Save…", systemImage: MachmanSymbols.saveToFile)
				}
				.disabled(connection == nil)
			}
			if let connection = connection {
				SerialTerminalView(connection: connection)
					.overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
			} else if disconnected {
				Text("Could not attach to \(socketPath).")
					.foregroundColor(.secondary)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.onAppear {
			let c = SerialTerminalConnection(path: socketPath)
			c.onClose = { disconnected = true }
			if c.connect() { connection = c } else { disconnected = true }
		}
		.onDisappear {
			connection?.stop()
			connection = nil
		}
		.id(socketPath)
	}

	private func save() {
		guard let data = connection?.transcriptData() else { return }
		let panel = NSSavePanel()
		panel.nameFieldStringValue = "serial.log"
		panel.allowedContentTypes = [.plainText]
		if panel.runModal() == .OK, let url = panel.url {
			try? data.write(to: url)
		}
	}
}
