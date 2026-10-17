//
//  DeviceInspectors.swift
//  MachmanDesktopUI
//
//  Inspectors for the guest devices (1.0.4 UI): graphics, network, clipboard, and Rosetta
//  carry settings (riding vm.device.update); every other kind gets DeviceInfoInspector —
//  what the device IS (Mac/Generic variant + the VZ class, for a docs lookup) and Remove.
//  Everything SSH lives in SSHInspector.swift; the two shared sections here
//  (DeviceImplementationSection, DeviceRemoveRow: Enabled and Remove) close every device
//  inspector.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

// Router for the device kinds: dedicated inspectors where there are settings, the generic
// info inspector everywhere else.
struct DeviceInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let kind: DeviceKind

	var body: some View {
		if let device = vm.devices?.first(where: { $0.kind == kind }) {
			switch device.kind {
			case .graphics:
				GraphicsInspector(viewModel: viewModel, vm: vm, device: device)
			case .network:
				NetworkInspector(viewModel: viewModel, vm: vm, device: device)
			case .clipboard:
				ClipboardInspector(viewModel: viewModel, vm: vm, device: device)
			case .rosetta:
				RosettaInspector(viewModel: viewModel, vm: vm, device: device)
			// The pre-1.0.7 installer kinds only appear from an older daemon; both route
			// to the unified installer's inspector like the kind they migrated into.
			case .guestSetup, .consoleLoginInstaller, .sshInstaller:
				GuestSetupInspector(viewModel: viewModel, vm: vm)
			case .unknown:
				NoSelectionInspector()
			default:
				DeviceInfoInspector(viewModel: viewModel, vm: vm, device: device)
			}
		} else {
			NoSelectionInspector()
		}
	}
}

// The generic inspector for kinds without settings: the host gate if any, what the device
// is, and Remove — selecting a keyboard is no longer a dead end.
struct DeviceInfoInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let device: DeviceInfo

	var body: some View {
		Form {
			if let gate = device.unavailable {
				UnavailableGateSection(gate)
			}
			DeviceImplementationSection(vm: vm, device: device)
			DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: device.kind)
		}
	}
}

// Shared "what IS this device" section: the Mac/Generic variant where it's meaningful and
// the VZ class the engine instantiates, copyable for a docs lookup. Sits directly above the
// remove row in every device inspector.
struct DeviceImplementationSection: View {
	let vm: VMInfo
	let device: DeviceInfo

	private var macGuest: Bool { vm.boot.mode == .macOS }

	var body: some View {
		Section("Implementation") {
			if let variant = device.kind.variantLabel(macGuest: macGuest) {
				LabeledContent("Variant", value: variant)
					.help(bootModeChoosesVariant
						? "Set by the boot mode: macOS guests get the Mac device, others the "
							+ "generic one"
						: "")
			}
			if let className = device.kind.vzClassName(macGuest: macGuest) {
				classRow("Class", className)
			}
			// The pasteboard rides a spice agent port on the clipboard's console device.
			if device.kind == .clipboard {
				classRow("Port", "VZSpiceAgentPortAttachment")
			}
			Text(caption)
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	// One sentence (X1); the clipboard names two classes, its device's and the Port row's.
	private var caption: String {
		device.kind == .clipboard
			? "The Virtualization framework classes behind this device, to look up in Apple’s "
				+ "documentation."
			: "The Virtualization framework class behind this device, to look up in Apple’s "
				+ "documentation."
	}

	// Why a keyboard or display is the Mac or the generic one; the Variant row's tooltip.
	private var bootModeChoosesVariant: Bool {
		device.kind == .keyboard || device.kind == .graphics
	}

	private func classRow(_ label: String, _ className: String) -> some View {
		LabeledContent(label) {
			HStack(spacing: 4) {
				Text(className)
					.font(.system(.caption, design: .monospaced))
					.textSelection(.enabled)
					.lineLimit(1)
					.truncationMode(.middle)
					.help(className)
				CopyToClipboardButton(className, tooltip: "Copy class name")
			}
		}
	}
}

// Shared trailing section: the device's Enabled toggle — the tree menu's Disable, here
// too (H58) — and Remove; both take effect at the next boot, like every device change.
struct DeviceRemoveRow: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let kind: DeviceKind

	private var device: DeviceInfo? { vm.devices?.first { $0.kind == kind } }

	var body: some View {
		Section {
			Toggle("Enabled", isOn: Binding(
				get: { device?.enabled ?? true },
				set: { viewModel.setEnabled(vm.name, devices: [kind.rawValue: $0]) }))
				.help("Disabled devices are left out at the next start")
			HStack {
				IconButton(
					symbol: MachmanSymbols.delete,
					tooltip: "Remove \(kind.displayLabel)"
				) {
					viewModel.removeDevice(vm.name, kind: kind)
				}
				Spacer()
			}
		}
	}
}

// MARK: - Graphics ----------------------------------------------------------------------------

// Display size as a resolution selector (design): Auto (host-sized at start), the common
// resolutions plus the actual host display, or Custom — which reveals the width/height
// fields. Bounds mirror the daemon's validation (640…8192 px, 40…300 ppi).
struct GraphicsInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let device: DeviceInfo
	@State private var customMode = false
	@State private var customWidth = 1920
	@State private var customHeight = 1080

	private enum Resolution: Hashable {
		case auto
		case preset(Int, Int)
		case custom
	}

	private var commonPresets: [DisplayResolutionPreset] {
		GraphicsChoices.resolutionPresets(
			hostWidth: viewModel.capabilities?.hostDisplayWidthPixels,
			hostHeight: viewModel.capabilities?.hostDisplayHeightPixels)
	}

	private var currentResolution: Resolution {
		if customMode { return .custom }
		guard let w = device.displayWidthPixels, let h = device.displayHeightPixels else {
			return .auto
		}
		return commonPresets.contains(DisplayResolutionPreset(width: w, height: h))
			? .preset(w, h) : .custom
	}

	var body: some View {
		Form {
			Section("Display") {
				Picker("Resolution", selection: resolutionBinding) {
					Text("Auto (Host Screen)").tag(Resolution.auto)
					ForEach(commonPresets) { preset in
						Text(presetLabel(preset.width, preset.height))
							.tag(Resolution.preset(preset.width, preset.height))
					}
					Text("Custom…").tag(Resolution.custom)
				}
				if currentResolution == .custom {
					LabeledContent("Width") {
						TextField("", value: $customWidth, format: .number)
							.inspectorNumberField(width: 70)
							.onSubmit { commitCustom() }
					}
					LabeledContent("Height") {
						TextField("", value: $customHeight, format: .number)
							.inspectorNumberField(width: 70)
							.onSubmit { commitCustom() }
					}
				}
				if vm.boot.mode == .macOS {
					LabeledContent("Pixels per inch") {
						TextField("", value: ppiBinding, format: .number, prompt: Text("80"))
							.inspectorNumberField(width: 70)
					}
				}
				Text("Auto follows the host screen at each start, and changes apply at the "
					+ "next boot.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Section {
				Picker("Capture system keys", selection: captureBinding) {
					ForEach(
						GraphicsChoices.captureModes(current: device.systemKeyCapture),
						id: \.self
					) { mode in
						Text(mode.displayLabel).tag(mode)
					}
				}
				.help("Sends shortcuts like ⌘Space and ⌘Tab to the guest, and ⌃⌥⌘K turns "
					+ "it on or off while the VM runs")
			}
			DeviceImplementationSection(vm: vm, device: device)
			DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .graphics)
		}
		.onAppear { seedCustomFields() }
	}

	private func presetLabel(_ w: Int, _ h: Int) -> String {
		let host = viewModel.capabilities?.hostDisplayWidthPixels == w
			&& viewModel.capabilities?.hostDisplayHeightPixels == h
		return host ? "Host Display (\(w) × \(h))" : "\(w) × \(h)"
	}

	private var resolutionBinding: Binding<Resolution> {
		Binding(
			get: { currentResolution },
			set: { choice in
				switch choice {
				case .auto:
					customMode = false
					commit(width: nil, height: nil)
				case .preset(let w, let h):
					customMode = false
					commit(width: w, height: h)
				case .custom:
					seedCustomFields()
					customMode = true   // fields appear; commit happens on submit
				}
			})
	}

	private func seedCustomFields() {
		customWidth = device.displayWidthPixels
			?? viewModel.capabilities?.hostDisplayWidthPixels ?? 1920
		customHeight = device.displayHeightPixels
			?? viewModel.capabilities?.hostDisplayHeightPixels ?? 1080
	}

	private func commitCustom() {
		customWidth = max(640, min(8192, customWidth))
		customHeight = max(640, min(8192, customHeight))
		commit(width: customWidth, height: customHeight)
	}

	private func commit(width: Int?, height: Int?) {
		var updated = device
		updated.displayWidthPixels = width
		updated.displayHeightPixels = height
		viewModel.updateDevice(vm.name, device: updated)
	}

	private var ppiBinding: Binding<Int?> {
		Binding(
			get: { device.displayPixelsPerInch },
			set: { value in
				var updated = device
				updated.displayPixelsPerInch = value.map { max(40, min(300, $0)) }
				viewModel.updateDevice(vm.name, device: updated)
			})
	}

	// The default a run starts with (the run's own value lives in the VM window's menu).
	private var captureBinding: Binding<SystemKeyCapture> {
		Binding(
			get: { device.systemKeyCapture ?? .off },
			set: { value in
				var updated = device
				updated.systemKeyCapture = value
				viewModel.updateDevice(vm.name, device: updated)
			})
	}
}

// MARK: - Network -----------------------------------------------------------------------------

// The MAC address's ONLY home (per the design): shown, copyable, regenerable while stopped.
struct NetworkInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let device: DeviceInfo
	@State private var regenConfirm = false

	var body: some View {
		Form {
			Section("Network") {
				LabeledContent("Attachment", value: "NAT")
					.help("Bridged networking is a future attachment kind")
				LabeledContent("MAC") {
					HStack(spacing: 4) {
						Text(vm.macAddress ?? "— (assigned on first boot)")
							.font(.system(.callout, design: .monospaced))
							.foregroundStyle(vm.macAddress == nil ? .secondary : .primary)
						if let mac = vm.macAddress {
							CopyToClipboardButton(mac, tooltip: "Copy MAC address")
							// The shared stop-first rule (P37): also held while the VM's state
							// is unknown, with the reason to wait.
							IconButton(
								symbol: MachmanSymbols.regenerate,
								name: "Regenerate MAC address…",
								disabledReason: vm.refusal(.regenerateMAC),
								font: .callout, flat: true
							) {
								regenConfirm = true
							}
						}
					}
				}
			}
			// The address is a fact of the network device; everything SSH lives in the
			// tree's SSH section, which is one place instead of three.
			NetworkAddressSection(viewModel: viewModel, vm: vm)
			DeviceImplementationSection(vm: vm, device: device)
			DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .network)
		}
		.confirmationDialog("Regenerate MAC address?", isPresented: $regenConfirm) {
			Button("Regenerate") { viewModel.regenerateMAC(vm.name) }
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("\(vm.name) gets a new random MAC address, so DHCP leases and network rules "
				+ "tied to the old one stop matching.")
		}
	}
}

// MARK: - Clipboard ---------------------------------------------------------------------------

// The spice-agent console port (EFI/kernel guests): whether the pasteboard is shared.
struct ClipboardInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let device: DeviceInfo

	var body: some View {
		Form {
			Section("Clipboard sharing") {
				Toggle("Share clipboard with guest", isOn: Binding(
					get: { device.sharesClipboard ?? true },
					set: { value in
						var updated = device
						updated.sharesClipboard = value
						viewModel.updateDevice(vm.name, device: updated)
					}))
				Text("Needs spice-vdagent running in the guest and applies at the next boot.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			DeviceImplementationSection(vm: vm, device: device)
			DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .clipboard)
		}
	}
}

// MARK: - Rosetta -----------------------------------------------------------------------------

// Host availability from capabilities (host.installRosetta flips it), the fixed mount tag,
// and the guide to set it up in the guest.
struct RosettaInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let device: DeviceInfo
	@State private var showGuide = false

	private var availability: String? { viewModel.capabilities?.rosettaAvailability }

	var body: some View {
		Form {
			Section("Rosetta x86-64") {
				LabeledContent("Status") {
					switch availability {
					case RosettaAvailability.installed:
						Label("Installed", systemImage: MachmanSymbols.activeEntry)
							.foregroundStyle(MachmanColors.stateRunning)
					case RosettaAvailability.notInstalled:
						Label("Not installed", systemImage: MachmanSymbols.warning)
							.foregroundStyle(MachmanColors.warning)
					case RosettaAvailability.notSupported:
						Label("Not supported on this host",
							systemImage: MachmanSymbols.warning)
							.foregroundStyle(MachmanColors.warning)
					default:
						Text("Unknown").foregroundStyle(.secondary)
					}
				}
				if availability == RosettaAvailability.notInstalled {
					Button("Install Rosetta Support…") {
						viewModel.installRosetta()
					}
					.liveWhileSettingsLocked()   // installs on this Mac, not in the VM
					.help("macOS asks before downloading, and the share attaches at the VM’s "
						+ "next boot")
				}
				if let gate = device.unavailable {
					Text(gate.message)
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
				LabeledContent("Mount tag", value: "rosetta")
			}
			// The commands live in the guide (RosettaHelpSheet): a copy button copies only a
			// command, never prose. Not "Guest Setup" — that name belongs to the installer.
			Section("In the guest") {
				Text("Linux guests run x86-64 binaries once they mount the share and register "
					+ "Rosetta.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				GuideButton(isPresented: $showGuide, help: "How to set Rosetta up in the guest")
			}
			DeviceImplementationSection(vm: vm, device: device)
			DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .rosetta)
		}
		.sheet(isPresented: $showGuide) {
			RosettaHelpSheet().liveWhileSettingsLocked()
		}
	}
}

// MARK: - Guest address ---------------------------------------------------------------------

// The guest's discovered address — a fact of the running VM (leases/ARP by its MAC, or what
// the guest reported), not of SSH, so it shows for every VM whether or not SSH is set up.
struct NetworkAddressSection: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo

	var body: some View {
		Section("Guest address") {
			LabeledContent("IP") {
				HStack(spacing: 4) {
					if let address = vm.ssh?.address {
						Text(address)
							.font(.system(.callout, design: .monospaced))
						CopyToClipboardButton(address, tooltip: "Copy address")
					} else {
						Text(vm.state.isRunning ? "Discovering…" : "— (start the VM)")
							.foregroundStyle(.secondary)
					}
					if vm.state.isRunning {
						IconButton(symbol: MachmanSymbols.rediscoverAddress,
							tooltip: "Re-run address discovery", font: .callout,
							flat: true) {
							viewModel.refreshSSH(vm.name)
						}
						.liveWhileSettingsLocked()   // allowed on an outdated vmhost
					}
				}
			}
			if let caption = Self.sourceCaption(vm.ssh?.addressSource) {
				Text(caption)
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
		}
	}

	// Where discovery found the address; nothing for a source this build doesn't know.
	static func sourceCaption(_ source: String?) -> String? {
		switch source {
		case "dhcp": "Found in this Mac’s DHCP leases."
		case "arp": "Found in the ARP table."
		case "report": "Reported by the guest."
		default: nil
		}
	}
}
