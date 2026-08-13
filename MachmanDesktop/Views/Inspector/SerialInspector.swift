//
//  SerialInspector.swift
//  MachmanDesktop
//
//  The serial-port inspector (1.0.4 UI), absorbing the old TerminalInfoPanel: host
//  unavailability (a gated uart leads with the reason), terminal profile with New/Edit and
//  the Reload hint when startup-only settings drifted, the data-plane socket, per-port file
//  logging, guest device names + setup notes, and — for uarts — the probed platform info.
//

import SwiftUI
import MachmanUI
import MachmanAPI

struct SerialInspector: View {
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
	private var gate: UnavailabilityInfo? { port?.unavailable }

	var body: some View {
		Form {
			if let gate {
				Section {
					Label {
						VStack(alignment: .leading, spacing: 3) {
							Text("Unavailable on this host")
								.fontWeight(.medium)
							Text(gate.message)
								.font(.caption)
								.foregroundStyle(.secondary)
								.fixedSize(horizontal: false, vertical: true)
						}
					} icon: {
						Image(systemName: MachmanSymbols.warning)
							.foregroundStyle(MachmanColors.warning)
					}
				}
			}
			terminalSection
			socketSection
			loggingSection
			guestDeviceSection
			if kind == .uart, port?.mmioBase != nil || port?.irq != nil {
				platformSection
			}
		}
	}

	// MARK: - Terminal profile

	private var terminalSection: some View {
		Section("Terminal") {
			Picker("Profile", selection: profileBinding) {
				ForEach(profiles.profiles) { p in
					Text(p.name).tag(p.id)
				}
			}
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
				HStack(spacing: 6) {
					Image(systemName: MachmanSymbols.reloadTerminal)
						.foregroundColor(.orange)
					Text("Startup settings changed.")
						.font(.caption).foregroundColor(.secondary)
					Spacer()
					Button("Reload") { reload() }.font(.caption)
						.disabled(gate != nil)
				}
			}
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

	// MARK: - Socket / logging

	private var socketSection: some View {
		Section("Socket") {
			if gate != nil {
				LabeledContent("Path", value: "— (not attached on this host)")
			} else if let sock = port?.socketPath {
				HStack {
					Text(sock)
						.font(.system(.caption, design: .monospaced))
						.lineLimit(1).truncationMode(.middle)
						.help(sock)
					Spacer(minLength: 4)
					CopyToClipboardButton(sock, tooltip: "Copy socket path")
				}
			} else {
				LabeledContent("Path", value: "— (socket exists while running)")
			}
		}
	}

	private var loggingSection: some View {
		Section("Logging") {
			Picker("Mode", selection: modeBinding) {
				Text("Disabled").tag(SerialLogMode.disabled)
				Text("Reset on boot").tag(SerialLogMode.resetOnBoot)
				Text("Continuous").tag(SerialLogMode.continuous)
			}
			Picker("Max size", selection: sizeBinding) {
				Text("Unlimited").tag(UInt64(0))
				Text("1 MB").tag(UInt64(1 << 20))
				Text("10 MB").tag(UInt64(10 << 20))
				Text("100 MB").tag(UInt64(100 << 20))
			}
			.disabled(port?.logging.mode == .disabled)
			if let logPath = port?.logPath {
				Text("Logging to \(logPath)")
					.font(.caption).foregroundColor(.secondary)
					.lineLimit(1).truncationMode(.middle)
			}
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

	// MARK: - Guest device / platform

	private var guestDeviceSection: some View {
		Section("Guest Device") {
			LabeledContent("Linux") {
				Text("/dev/" + kind.guestDevice(index: index, macGuest: false))
					.font(.system(.callout, design: .monospaced))
			}
			if kind == .console {
				LabeledContent("macOS") {
					Text("/dev/" + kind.guestDevice(index: index, macGuest: true))
						.font(.system(.callout, design: .monospaced))
				}
			}
			Text(setupNote)
				.font(.caption)
				.foregroundColor(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	// From the generated platform info the daemon serves for uarts.
	private var platformSection: some View {
		Section("Probed Platform Info") {
			if let mmio = port?.mmioBase {
				LabeledContent("MMIO base") {
					Text(mmio).font(.system(.callout, design: .monospaced))
				}
			}
			if let irq = port?.irq {
				LabeledContent("IRQ") {
					Text("\(irq)").font(.system(.callout, design: .monospaced))
				}
			}
		}
	}

	private var setupNote: String {
		switch (kind, macGuest) {
		case (.console, false):
			return "Linux (systemd) starts a login on hvc\(index) automatically. Add "
				+ "console=hvc\(index) to the kernel command line to also see boot messages."
		case (.uart, false):
			return "Drivable by a bare-metal kernel, or add console=ttyAMA\(index) to a "
				+ "Linux kernel command line."
		case (.console, true):
			return "macOS runs no getty on serial by default — configure one in the guest "
				+ "(launchd) to get a login shell."
		case (.uart, true):
			return "On a macOS guest the PL011 is the kernel debug UART; it needs reduced "
				+ "security in the guest (boot-args serial=3) and has no userland device."
		}
	}
}
