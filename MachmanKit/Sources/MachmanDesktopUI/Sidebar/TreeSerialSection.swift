//
//  TreeSerialSection.swift
//  MachmanDesktopUI
//
//  The device tree's Serial section: console and UART ports (VMDeviceTreeView).
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct TreeSerialSection: View {
	let ctx: TreeContext
	@Environment(\.machmanTheme) private var theme

	var body: some View {
		// Search matches the display name AND the raw guest device (hvc0 finds
		// "Console 0" on an EFI VM).
		let ports = ctx.sectionRows(.serial, ctx.vm.allSerialPorts) {
			ctx.matches($0.displayName(mode: ctx.vm.boot.mode)) || ctx.matches($0.guestDevice)
				|| ctx.matches($0.guestName)
		}
		// Selectable (the SSH-group pattern): the group inspector lists every interface
		// with the login state the guest-setup script reported.
		if ctx.shows(.serial, rows: ports.count) {
			TreeGroup(.group("Serial"), symbol: MachmanSymbols.serialUart, title: "Serial",
				count: ctx.vm.allSerialPorts.count, selectable: true,
				isExpanded: ctx.groupBinding(.group("Serial"))) {
				ForEach(ports) { port in
					serialRow(port)
				}
			}
		}
	}

	private func serialRow(_ port: SerialPortInfo) -> some View {
		let ref = SerialPortRef(port)
		// Open counts a torn-off window too: the terminal is live either way.
		let open = ctx.canvases.canvas(for: ctx.vm.name).allOpenTabs.contains(.terminal(ref))
			|| ctx.isTorn(.terminal(ref))
		let gated = port.unavailable != nil
		let enabled = port.enabled ?? true
		return HStack(spacing: 6) {
			Image(systemName: port.kind == .console
				? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
				.font(.system(size: theme.metrics.iconSize))
			Text(port.displayName(mode: ctx.vm.boot.mode))
			Spacer()
			if gated {
				Image(systemName: MachmanSymbols.warning)
					.font(.system(size: 10))
					.foregroundStyle(MachmanColors.warning)
					.help(port.unavailable?.message ?? "Unavailable on this host")
			}
			if open {
				Circle().fill(theme.accentColor)
					.frame(width: 5, height: 5)
					.help("Terminal open")
			}
		}
		.treeRow(
			.serial(ref),
			opacity: !enabled ? MachmanColors.inactiveEntryOpacity
				: (gated ? MachmanColors.dimmedRowOpacity : 1),
			onClick: { ctx.clicked(.serial(ref)) }
		) { ctx.serialMenu(port, ref: ref, open: open, gated: gated, enabled: enabled) }
	}
}
