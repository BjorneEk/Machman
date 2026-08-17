//
//  DeviceInspectors.swift
//  MachmanDesktop
//
//  Inspectors for the guest devices (1.0.4 UI): graphics, network, clipboard, and Rosetta
//  carry settings (riding vm.device.update); every other kind gets DeviceInfoInspector —
//  what the device IS (Mac/Generic variant + the VZ class, for a docs lookup) and Remove.
//  Everything SSH lives in SSHInspector.swift; the two shared sections here
//  (DeviceImplementationSection, DeviceRemoveRow) close every device inspector.
//

import SwiftUI
import MachmanUI
import MachmanAPI

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
			}
			if let className = device.kind.vzClassName(macGuest: macGuest) {
				LabeledContent("Class") {
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
			Text(caption)
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var caption: String {
		var text = "The Virtualization framework class this device instantiates — "
			+ "searchable in Apple's developer documentation."
		switch device.kind {
		case .keyboard, .graphics:
			text += " Chosen by the VM's boot mode: macOS guests get the Mac device, EFI "
				+ "and kernel boots the generic one."
		case .clipboard:
			text += " The sharing itself is a spice agent port (VZSpiceAgentPortAttachment) "
				+ "on this console device."
		default:
			break
		}
		return text
	}
}

// Shared trailing row: remove the device (next-boot effect, like every device change).
struct DeviceRemoveRow: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let kind: DeviceKind

	var body: some View {
		Section {
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

	private var commonPresets: [(Int, Int)] {
		var presets: [(Int, Int)] = []
		if let w = viewModel.capabilities?.hostDisplayWidthPixels,
			let h = viewModel.capabilities?.hostDisplayHeightPixels {
			presets.append((w, h))
		}
		for p in [(1280, 800), (1920, 1080), (2560, 1440), (2560, 1600),
			(3024, 1964), (3456, 2234), (3840, 2160)]
			where !presets.contains(where: { $0 == p }) {
			presets.append(p)
		}
		return presets
	}

	private var currentResolution: Resolution {
		if customMode { return .custom }
		guard let w = device.displayWidthPixels, let h = device.displayHeightPixels else {
			return .auto
		}
		return commonPresets.contains(where: { $0 == (w, h) }) ? .preset(w, h) : .custom
	}

	var body: some View {
		Form {
			Section("Display") {
				Picker("Resolution", selection: resolutionBinding) {
					Text("Auto (host screen)").tag(Resolution.auto)
					ForEach(commonPresets, id: \.0) { w, h in
						Text(presetLabel(w, h)).tag(Resolution.preset(w, h))
					}
					Text("Custom…").tag(Resolution.custom)
				}
				if currentResolution == .custom {
					LabeledContent("Width") {
						TextField("", value: $customWidth, format: .number)
							.textFieldStyle(.plain)
							.multilineTextAlignment(.trailing)
							.frame(width: 70)
							.onSubmit { commitCustom() }
					}
					LabeledContent("Height") {
						TextField("", value: $customHeight, format: .number)
							.textFieldStyle(.plain)
							.multilineTextAlignment(.trailing)
							.frame(width: 70)
							.onSubmit { commitCustom() }
					}
				}
				if vm.boot.mode == .macOS {
					LabeledContent("Pixels per inch") {
						TextField("80", value: ppiBinding, format: .number)
							.textFieldStyle(.plain)
							.multilineTextAlignment(.trailing)
							.frame(width: 70)
					}
				}
				Text("Auto sizes from the host screen at start. Changes apply at the "
					+ "next boot.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			DeviceImplementationSection(vm: vm, device: device)
			DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .graphics)
		}
		.onAppear { seedCustomFields() }
	}

	private func presetLabel(_ w: Int, _ h: Int) -> String {
		let host = viewModel.capabilities?.hostDisplayWidthPixels == w
			&& viewModel.capabilities?.hostDisplayHeightPixels == h
		return host ? "Host display (\(w) × \(h))" : "\(w) × \(h)"
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
							IconButton(
								symbol: MachmanSymbols.regenerate,
								tooltip: vm.state.isRunning
									? "Stop the VM to change its MAC address"
									: "New MAC address (guest sees it on next boot)",
								font: .callout, flat: true
							) {
								regenConfirm = true
							}
							.disabled(vm.state.isRunning)
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
			Text("\(vm.name) gets a new random MAC. DHCP leases and MAC-based network "
				+ "rules tied to the old address will stop matching.")
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
			Section("Clipboard Sharing") {
				Toggle("Share clipboard with guest", isOn: Binding(
					get: { device.sharesClipboard ?? true },
					set: { value in
						var updated = device
						updated.sharesClipboard = value
						viewModel.updateDevice(vm.name, device: updated)
					}))
				Text("Spice agent port — Linux/EFI guests only (macOS guests don't "
					+ "support it). The guest needs spice-vdagent running. Applies at "
					+ "the next boot.")
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
// and the guest binfmt setup.
struct RosettaInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let device: DeviceInfo

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
					.help("macOS prompts for the download; the VM's share attaches on "
						+ "the next boot once installed")
				}
				if let gate = device.unavailable {
					Text(gate.message)
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
				LabeledContent("Mount tag", value: "rosetta")
			}
			Section("Guest Setup") {
				VStack(alignment: .leading, spacing: 6) {
					Text("Mount the share, then register the binfmt handler:")
						.font(.caption)
						.foregroundStyle(.secondary)
					CommandBlock(Self.setupCommand, tooltip: "Copy commands")
					Text("Lets Linux guests run x86-64 binaries through Rosetta.")
						.font(.caption)
						.foregroundStyle(.tertiary)
				}
			}
			DeviceImplementationSection(vm: vm, device: device)
			DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .rosetta)
		}
	}

	private static let setupCommand = "mount -t virtiofs rosetta /media/rosetta\n"
		+ "/media/rosetta/rosetta must be registered with binfmt_misc "
		+ "(see Apple's VZLinuxRosettaDirectoryShare docs)"
}

// MARK: - Guest address ---------------------------------------------------------------------

// The guest's discovered address — a fact of the running VM (leases/ARP by its MAC),
// not of SSH, so it shows for every VM whether or not SSH is set up.
struct NetworkAddressSection: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo

	var body: some View {
		Section("Guest Address") {
			LabeledContent("IP") {
				HStack(spacing: 4) {
					if let address = vm.ssh?.address {
						Text(address)
							.font(.system(.callout, design: .monospaced))
						CopyToClipboardButton(address, tooltip: "Copy address")
					} else {
						Text(vm.state.isRunning ? "discovering…" : "— (start the VM)")
							.foregroundStyle(.secondary)
					}
					if vm.state.isRunning {
						IconButton(symbol: MachmanSymbols.regenerate,
							tooltip: "Re-run address discovery", font: .callout,
							flat: true) {
							viewModel.refreshSSH(vm.name)
						}
					}
				}
			}
			if let source = vm.ssh?.addressSource {
				Text(source == "dhcp" ? "via the host's DHCP leases" : "via the ARP table")
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
		}
	}
}
