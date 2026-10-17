//
//  SerialInspector.swift
//  MachmanDesktopUI
//
//  The serial-port inspector (1.0.4 UI), absorbing the old TerminalInfoPanel: host
//  unavailability (a gated uart leads with the reason), terminal profile with New/Edit and
//  the Reload hint when startup-only settings drifted, the data-plane socket, per-port file
//  logging, guest device names by boot mode (+ the console Setup Guide sheet), for uarts
//  the probed platform info, and last the port's Enabled toggle and, on a kind's last port,
//  Remove — what the tree's menu offers (H58).
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct SerialInspector: View {
	let vm: VMInfo
	let ref: SerialPortRef
	@ObservedObject var viewModel: VMListViewModel
	@ObservedObject var sessions: TerminalSessions
	@ObservedObject var profiles: TerminalProfileStore
	@Environment(\.openSettings) private var openSettings
	@State private var showSetupGuide = false

	private var kind: SerialPortKind { ref.kind }
	private var index: Int { ref.index }
	private var macGuest: Bool { vm.boot.mode == .macOS }
	private var port: SerialPortInfo? { vm.port(for: ref) }
	private var gate: UnavailabilityInfo? { port?.unavailable }
	// The compacted index the guest actually sees (older daemons don't serve it — fall
	// back to the config position, matching their config-indexed guestDevice).
	private var guestIndex: Int { port?.guestIndex ?? index }

	var body: some View {
		Form {
			if let gate {
				UnavailableGateSection(gate)
			}
			terminalSection
			socketSection
			loggingSection
			guestDeviceSection
			if kind == .uart, port?.mmioBase != nil || port?.irq != nil {
				platformSection
			}
			portSection
		}
		.sheet(isPresented: $showSetupGuide) {
			GuestSetupHelpSheet(vm: vm).liveWhileSettingsLocked()
		}
	}

	// MARK: - Terminal profile

	// Icon actions only (design): reload (always visible) + terminal settings, the
	// tooltips carrying the descriptions, on a row of their own under the picker — beside
	// it they cut its value to a stub at the inspector's floor (L7).
	private var terminalSection: some View {
		Section("Terminal") {
			Picker("Profile", selection: profileBinding) {
				ForEach(profiles.profiles) { p in
					Text(p.name).tag(p.id)
				}
			}
			.help(profiles.profile(vm: vm.name, ref: ref).name)
			.liveWhileSettingsLocked()   // the desktop's own choice, not the VM's
			HStack(spacing: 4) {
				IconButton(
					symbol: MachmanSymbols.reloadTerminal,
					tooltip: "Reload the terminal — rebuilds it with the profile’s "
						+ "startup settings (scrollback, TERM, cursor) and reconnects",
					flat: true
				) {
					reload()
				}
				.disabled(gate != nil || sessions.controller(vm: vm.name, ref: ref) == nil)
				terminalSettingsButton
				Spacer()
			}
			.liveWhileSettingsLocked()
			if reloadNeeded {
				Text("Startup settings changed — reload to apply.")
					.font(.caption)
					.foregroundColor(MachmanColors.warning)
			}
		}
	}

	// Terminal-with-a-gear glyph: opens Settings on this port's profile.
	private var terminalSettingsButton: some View {
		Button {
			profiles.editingProfileID = profiles.associatedID(vm: vm.name, ref: ref)
			openSettings()
		} label: {
			ZStack(alignment: .bottomTrailing) {
				Image(systemName: MachmanSymbols.serialConsole)
					.font(.system(size: 13))
				Image(systemName: MachmanSymbols.tabConfig)
					.font(.system(size: 8, weight: .bold))
					.padding(1)
					.background(Circle().fill(.background))
					.offset(x: 4, y: 3)
			}
			.frame(width: 22, height: 20)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.machmanHoverable()
		.help("Edit this port’s profile in Settings")
		.accessibilityLabel("Edit this port’s profile in Settings")   // image-only (H32)
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
				PathRow(label: "Path", path: sock) { Finder.reveal(sock) }
			} else {
				LabeledContent("Path", value: "— (socket exists while running)")
			}
		}
	}

	private var loggingSection: some View {
		Section("Logging") {
			Picker("Mode", selection: modeBinding) {
				ForEach(Self.logModes, id: \.mode) { item in
					Text(item.label).tag(item.mode)
				}
			}
			.help(Self.logModes.first { $0.mode == modeBinding.wrappedValue }?.label ?? "")
			let caps = SerialLogCaps.items(current: port?.logging.maxBytes)
			Picker("Max size", selection: sizeBinding) {
				ForEach(caps, id: \.bytes) { item in
					Text(item.label).tag(item.bytes)
				}
			}
			.help(caps.first { $0.bytes == sizeBinding.wrappedValue }?.label ?? "")
			.disabled(port?.logging.mode == .disabled)
			if let logPath = port?.logPath {
				PathRow(label: "Log file", path: logPath) { Finder.reveal(logPath) }
			}
		}
	}

	private static let logModes: [(mode: SerialLogMode, label: String)] = [
		(.disabled, "Disabled"), (.resetOnBoot, "Reset on Boot"), (.continuous, "Continuous"),
	]

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

	// Device rows match the boot mode: a kernel boot IS Linux, a macOS guest is macOS, and
	// an EFI guest can boot anything — show the plausible conventions UNTIL the guest has
	// reported the real name, which then replaces the speculation with one row. Every
	// console gets the Setup Guide sheet; a kernel-boot console keeps one sentence too.
	private var guestDeviceSection: some View {
		Section("Guest device") {
			if let name = port?.guestName {
				LabeledContent(GuestOSName.display(vm.setup?.guestOS)) {
					Text("/dev/" + name)
						.font(.system(.callout, design: .monospaced))
				}
				setupGuideButton
			} else {
				switch (kind, vm.boot.mode) {
				case (.console, .efi), (.console, .unknown):
					deviceRow("Linux", os: .linux)
					deviceRow("FreeBSD", os: .freebsd)
					setupGuideButton
				case (.console, .macOS):
					deviceRow("macOS", os: .macOS)
					setupGuideButton
				case (.unknown, _):
					EmptyView()
				case (.uart, .macOS):
					// The kernel's debug UART: no userland device to name, only the note.
					Text(setupNote)
						.font(.caption)
						.foregroundColor(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				case (.console, .linuxKernel):
					deviceRow("Linux", os: .linux)
					Text(setupNote)
						.font(.caption)
						.foregroundColor(.secondary)
						.fixedSize(horizontal: false, vertical: true)
					setupGuideButton
				case (.uart, _):
					deviceRow("Linux", os: .linux)
					Text(setupNote)
						.font(.caption)
						.foregroundColor(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
		}
	}

	private func deviceRow(_ label: String, os: SerialGuestOS) -> some View {
		LabeledContent(label) {
			Text("/dev/" + kind.guestDevice(index: guestIndex, os: os))
				.font(.system(.callout, design: .monospaced))
		}
	}

	private var setupGuideButton: some View {
		GuideButton(
			isPresented: $showSetupGuide,
			help: "How to set up this console inside the guest OS")
	}

	// From the generated platform info the daemon serves for uarts.
	private var platformSection: some View {
		Section("Probed platform info") {
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

	// MARK: - The port itself

	// The tree's Enable/Disable and Remove, here too (H58): Remove only on a kind's last
	// port (the remove APIs pop the highest index), stop-first as in the menu.
	private var portSection: some View {
		Section {
			Toggle("Enabled", isOn: enabledBinding)
				.help("Disabled ports are not attached at the next start")
			if vm.offersRemove(ref) {
				HStack {
					IconButton(
						symbol: MachmanSymbols.delete,
						name: kind == .console ? "Remove console port" : "Remove UART port",
						disabledReason: vm.refusal(.changeSerialPorts)
					) {
						if kind == .console {
							viewModel.removeConsolePort(vm.name)
						} else {
							viewModel.removeUartPort(vm.name)
						}
					}
					Spacer()
				}
			}
		}
	}

	private var enabledBinding: Binding<Bool> {
		Binding(
			get: { port?.isEnabled ?? true },
			set: { value in
				let change = [String(index): value]
				if kind == .console {
					viewModel.setEnabled(vm.name, console: change)
				} else {
					viewModel.setEnabled(vm.name, uart: change)
				}
			})
	}

	// Only the caption cases remain: kernel-boot consoles (beside their Setup Guide button)
	// and uarts; consoles on EFI/macOS have the Setup Guide sheet alone.
	private var setupNote: String {
		switch (kind, macGuest) {
		case (.console, _):
			return "Add console=hvc\(guestIndex) to the kernel command line to see boot "
				+ "messages here too."
		case (.uart, false):
			return "Drivable by a bare-metal kernel, or add console=ttyAMA\(guestIndex) to a "
				+ "Linux kernel command line."
		case (.uart, true):
			return "A macOS guest uses it as the kernel’s debug UART, set up with boot-args "
				+ "serial=3 under reduced security."
		case (.unknown, _):
			return ""   // unknown kinds never reach the caption branch
		}
	}
}
