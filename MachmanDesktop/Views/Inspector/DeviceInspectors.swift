//
//  DeviceInspectors.swift
//  MachmanDesktop
//
//  Inspectors for the configurable guest devices (1.0.4 UI): graphics, network, clipboard,
//  Rosetta. All settings ride vm.device.update; kinds without settings have no inspector
//  (the tree offers Remove only).
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI

// Router for the configurable device kinds.
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
				NetworkInspector(viewModel: viewModel, vm: vm)
			case .clipboard:
				ClipboardInspector(viewModel: viewModel, vm: vm, device: device)
			case .rosetta:
				RosettaInspector(viewModel: viewModel, vm: vm, device: device)
			default:
				NoSelectionInspector()
			}
		} else {
			NoSelectionInspector()
		}
	}
}

// Shared trailing row: remove the device (next-boot effect, like every device change).
private struct DeviceRemoveRow: View {
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

// Explicit display size (the engine falls back to the host screen when unset) and, for
// macOS guests, pixel density. Bounds mirror the daemon's validation (640…8192 px,
// 40…300 ppi).
struct GraphicsInspector: View {
	@ObservedObject var viewModel: VMListViewModel
	let vm: VMInfo
	let device: DeviceInfo

	var body: some View {
		Form {
			Section("Display") {
				LabeledContent("Width") {
					TextField("auto", value: dimensionBinding(\.displayWidthPixels),
						format: .number)
						.textFieldStyle(.plain)
						.multilineTextAlignment(.trailing)
						.frame(width: 70)
				}
				LabeledContent("Height") {
					TextField("auto", value: dimensionBinding(\.displayHeightPixels),
						format: .number)
						.textFieldStyle(.plain)
						.multilineTextAlignment(.trailing)
						.frame(width: 70)
				}
				if vm.boot.mode == .macOS {
					LabeledContent("Pixels per inch") {
						TextField("80", value: ppiBinding, format: .number)
							.textFieldStyle(.plain)
							.multilineTextAlignment(.trailing)
							.frame(width: 70)
					}
				}
				Menu("Preset") {
					if let w = viewModel.capabilities?.hostDisplayWidthPixels,
						let h = viewModel.capabilities?.hostDisplayHeightPixels {
						preset(w, h, label: "Host display (\(w) × \(h))")
					}
					preset(2560, 1440)
					preset(1920, 1080)
					preset(3456, 2234)
				}
				Text("Empty = sized from the host screen at start. Changes apply at the "
					+ "next boot.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .graphics)
		}
	}

	private func preset(_ w: Int, _ h: Int, label: String? = nil) -> some View {
		Button(label ?? "\(w) × \(h)") {
			var updated = device
			updated.displayWidthPixels = w
			updated.displayHeightPixels = h
			viewModel.updateDevice(vm.name, device: updated)
		}
	}

	private func dimensionBinding(
		_ key: WritableKeyPath<DeviceInfo, Int?>
	) -> Binding<Int?> {
		Binding(
			get: { device[keyPath: key] },
			set: { value in
				var updated = device
				updated[keyPath: key] = value.map { max(640, min(8192, $0)) }
				viewModel.updateDevice(vm.name, device: updated)
			})
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
					HStack {
						Text(Self.setupCommand)
							.font(.system(.caption, design: .monospaced))
							.textSelection(.enabled)
						Spacer()
						CopyToClipboardButton(Self.setupCommand, tooltip: "Copy commands")
					}
					.padding(6)
					.background(RoundedRectangle(cornerRadius: 5)
						.fill(Color.primary.opacity(0.05)))
					Text("Lets Linux guests run x86-64 binaries through Rosetta.")
						.font(.caption)
						.foregroundStyle(.tertiary)
				}
			}
			DeviceRemoveRow(viewModel: viewModel, vm: vm, kind: .rosetta)
		}
	}

	private static let setupCommand = "mount -t virtiofs rosetta /media/rosetta\n"
		+ "/media/rosetta/rosetta must be registered with binfmt_misc "
		+ "(see Apple's VZLinuxRosettaDirectoryShare docs)"
}
