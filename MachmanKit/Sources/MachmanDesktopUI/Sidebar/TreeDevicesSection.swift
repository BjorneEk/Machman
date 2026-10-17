//
//  TreeDevicesSection.swift
//  MachmanDesktopUI
//
//  The device tree's Installers and Devices sections (VMDeviceTreeView).
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct TreeDevicesSection: View {
	let ctx: TreeContext

	var body: some View {
		installerGroup
		deviceGroup
	}

	// Installer devices (share-served guest-setup payloads): their own section — they
	// configure the guest rather than being hardware. Guest Setup is the one installer and
	// the group shows only while it is attached, so its label has no menu: the toolbar's +
	// and the SSH inspector add it (Q30).
	@ViewBuilder
	private var installerGroup: some View {
		let installers = (ctx.vm.devices ?? []).filter(\.kind.isInstaller)
		let rows = ctx.sectionRows(.installers, installers) { ctx.matches($0.kind.displayLabel) }
		// The unified Guest Setup (the legacy Console Login / SSH Setup kinds migrate to it).
		if ctx.shows(.installers, rows: rows.count) {
			TreeGroup(.group("Installers"), symbol: MachmanSymbols.installerGroup,
				title: "Installers", count: installers.count,
				isExpanded: ctx.groupBinding(.group("Installers"))) {
				ForEach(rows) { device in
					deviceRow(device)
				}
			}
		}
	}

	// Guest devices from the engine's assembly. Every kind is selectable (kinds without
	// settings get the generic info inspector); disabled devices dim, and a host-gated one
	// (Rosetta not installed, nested unsupported) carries the warning + reason.
	@ViewBuilder
	private var deviceGroup: some View {
		// Installer kinds render under Installers instead.
		let devices = (ctx.vm.devices ?? []).filter { !$0.kind.isInstaller }
		let rows = ctx.sectionRows(.devices, devices) { ctx.matches($0.kind.displayLabel) }
		if ctx.shows(.devices, rows: rows.count) {
			TreeGroup(.group("Devices"), symbol: MachmanSymbols.deviceGroup, title: "Devices",
				count: devices.count, isExpanded: ctx.groupBinding(.group("Devices"))) {
				ForEach(rows) { device in
					deviceRow(device)
				}
			}
		}
	}

	private func deviceRow(_ device: DeviceInfo) -> some View {
		HStack(spacing: 6) {
			TreeIcon(symbol: device.kind.displaySymbol)
			Text(device.kind.displayLabel)
				.lineLimit(1)
			Spacer()
			if let gate = device.unavailable {
				TreeBadge.warning(gate.message)
			}
		}
		.treeRow(
			.device(device.kind),
			opacity: device.enabled ? 1 : MachmanColors.inactiveEntryOpacity
		) { ctx.deviceMenu(device) }
	}
}
