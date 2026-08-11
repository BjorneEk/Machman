//
//  TerminalInfoPanel.swift
//  MachmanDesktop
//
//  The right-hand pop-out for the active terminal tab: which terminal profile it uses (with a
//  New/Edit that opens the settings window, and a Reload when startup-only settings drifted), the
//  guest device name + per-platform setup notes, the data-plane socket path, and the per-port file
//  logging controls. Absorbs the former SerialPortDetailView Info tab. Shown only for a terminal
//  tab (the config tab has no socket).
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct TerminalInfoPanel: View {
	let vm: VMInfo
	let ref: SerialPortRef
	@ObservedObject var viewModel: VMListViewModel
	@ObservedObject var sessions: TerminalSessions
	@ObservedObject var profiles: TerminalProfileStore
	@Environment(\.openSettings) private var openSettings

	private var kind: SerialPortKind { ref.kind }
	private var index: Int { ref.index }
	private var macGuest: Bool { vm.boot.mode == .macOS }
	private var port: SerialPortInfo? {
		let ports = kind == .console ? vm.consolePorts : vm.uartPorts
		return ports?.first { $0.index == index }
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				profileBox
				guestDeviceBox
				socketBox
				loggingBox
			}
			.padding()
		}
		.frame(maxHeight: .infinity, alignment: .top)
	}

	// MARK: - Profile

	private var profileBox: some View {
		GroupBox("Terminal profile") {
			VStack(alignment: .leading, spacing: 8) {
				Picker("", selection: profileBinding) {
					ForEach(profiles.profiles) { p in
						Text(p.name).tag(p.id)
					}
				}
				.labelsHidden()
				HStack {
					Button {
						let p = profiles.addProfile()
						profiles.associate(vm: vm.name, ref: ref, to: p.id)
						profiles.editingProfileID = p.id
						applySelected()
						openSettings()
					} label: {
						Label("New…", systemImage: MachmanSymbols.add)
					}
					Button {
						profiles.editingProfileID = profiles.associatedID(vm: vm.name, ref: ref)
						openSettings()
					} label: {
						Label("Edit…", systemImage: MachmanSymbols.terminalProfile)
					}
					Spacer()
				}
				.font(.caption)
				if reloadNeeded {
					Divider()
					HStack(spacing: 6) {
						Image(systemName: MachmanSymbols.reloadTerminal)
							.foregroundColor(.orange)
						Text("Startup settings changed.")
							.font(.caption).foregroundColor(.secondary)
						Spacer()
						Button("Reload") { reload() }.font(.caption)
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	private var profileBinding: Binding<UUID> {
		Binding(
			get: { profiles.associatedID(vm: vm.name, ref: ref) },
			set: { id in
				profiles.associate(vm: vm.name, ref: ref, to: id)
				applySelected()
			})
	}

	// Apply the resolved profile's live settings now; startup differences surface as Reload.
	private func applySelected() {
		sessions.controller(vm: vm.name, ref: ref)?
			.applyLive(profiles.profile(vm: vm.name, ref: ref))
	}

	private var reloadNeeded: Bool {
		guard let c = sessions.controller(vm: vm.name, ref: ref) else { return false }
		return c.startupSignature != profiles.profile(vm: vm.name, ref: ref).startupSignature
	}

	private func reload() {
		sessions.reloadTab(
			vm: vm.name, ref: ref, socketPath: port?.socketPath,
			profile: profiles.profile(vm: vm.name, ref: ref))
	}

	// MARK: - Guest device

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
			// A Grid aligns the label column and the picker column, so both selectors are the same
			// width despite the different label lengths.
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
					vm.name, kind: kind, index: index,
					config: SerialLogConfig(mode: newMode, maxBytes: current.maxBytes))
			})
	}

	private var sizeBinding: Binding<UInt64> {
		Binding(
			get: { port?.logging.maxBytes ?? 0 },
			set: { newSize in
				guard let current = port?.logging else { return }
				viewModel.setSerialLogging(
					vm.name, kind: kind, index: index,
					config: SerialLogConfig(
						mode: current.mode, maxBytes: newSize == 0 ? nil : newSize))
			})
	}

	private func labeled(_ label: String, _ value: String) -> some View {
		HStack {
			Text(label).foregroundColor(.secondary).frame(width: 52, alignment: .leading)
			Text(value).font(.system(.body, design: .monospaced))
		}
	}
}
