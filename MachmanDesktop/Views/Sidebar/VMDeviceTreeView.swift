//
//  VMDeviceTreeView.swift
//  MachmanDesktop
//
//  The sidebar device tree (1.0.4 UI): the selected VM as root with Disks / Mounts / Serial
//  groups (Devices and Kernel/Initramfs land with their inspectors). Group parents are
//  dimmed and unselectable — entry rows carry the interaction: dim when disabled, link
//  badge on referenced files, warning + no tab for host-gated uarts, live dot on open
//  terminals. VM switching lives in the toolbar picker, not here.
//

import SwiftUI
import MachmanUI
import MachmanAPI

// Stable identity for every selectable row in the tree (multi-select + context menus).
enum SidebarNode: Hashable {
	case vmRoot
	case group(String)
	case disk(String)            // DiskInfo.id
	case mount(String)           // MountInfo.id
	case serial(SerialPortRef)
	case device(DeviceKind)
	case kernel(String)          // OwnedKernelFile.id (path)
	case initramfs(String)
}

struct VMDeviceTreeView: View {
	@ObservedObject var viewModel: VMListViewModel
	@ObservedObject var sessions: TerminalSessions
	let vm: VMInfo
	@State private var treeSelection: Set<SidebarNode> = []
	@State private var expanded: Set<SidebarNode> = [
		.group("Disks"), .group("Mounts"), .group("Serial"), .group("Devices"),
	]
	@Environment(\.machmanTheme) private var theme

	var body: some View {
		List(selection: $treeSelection) {
			vmRootRow
			diskGroup
			mountGroup
			serialGroup
			deviceGroup
		}
		.listStyle(.sidebar)
		.environment(\.defaultMinListRowHeight, theme.metrics.treeRowHeight)
		.font(.system(size: theme.metrics.rowFontSize))
		.onChange(of: treeSelection) {
			guard treeSelection.count == 1, let node = treeSelection.first else { return }
			openNode(node)
		}
		// The tree shows ONE VM; stale nodes must not survive into another VM's tree.
		.onChange(of: vm.name) {
			treeSelection = []
		}
	}

	// MARK: - Rows

	private var vmRootRow: some View {
		HStack(spacing: 6) {
			StatusDot(state: vm.state, size: 8)
			Text(vm.name).fontWeight(.semibold)
			if vm.safeRun == true { SafeBadge(compact: true) }
			Spacer()
			BootBadge(mode: vm.boot.mode, size: 9)
		}
		.frame(height: theme.metrics.treeRowHeight)
		.tag(SidebarNode.vmRoot)
	}

	@ViewBuilder
	private var diskGroup: some View {
		let disks = vm.disks
		group(.group("Disks"), symbol: MachmanSymbols.diskName, title: "Disks",
			count: disks.count) {
			ForEach(disks) { disk in
				HStack(spacing: 6) {
					Image(systemName: Self.symbol(for: disk.type))
						.font(.system(size: theme.metrics.iconSize))
						.foregroundStyle(disk.owned == false ? Color.secondary : Color.primary)
					Text(disk.name ?? Self.lastComponent(disk.path))
						.truncationMode(.middle)
						.lineLimit(1)
					Spacer()
					if disk.owned == false {
						Image(systemName: MachmanSymbols.externalReference)
							.font(.system(size: 9))
							.foregroundStyle(.tertiary)
							.help("Referenced — lives outside the VM directory")
					}
				}
				.opacity(disk.isEnabled ? 1 : MachmanColors.inactiveEntryOpacity)
				.frame(height: theme.metrics.treeRowHeight)
				.tag(SidebarNode.disk(disk.id))
			}
		}
	}

	@ViewBuilder
	private var mountGroup: some View {
		let mounts = vm.mounts
		group(.group("Mounts"), symbol: MachmanSymbols.mount, title: "Mounts",
			count: mounts.count) {
			ForEach(mounts) { mount in
				HStack(spacing: 6) {
					Image(systemName: MachmanSymbols.mount)
						.font(.system(size: theme.metrics.iconSize))
					Text(Self.abbreviate(mount.path))
						.truncationMode(.middle)
						.lineLimit(1)
						.help("\(mount.path) — guest tag “\(mount.tag)”")
					Spacer()
				}
				.opacity(mount.isEnabled ? 1 : MachmanColors.inactiveEntryOpacity)
				.frame(height: theme.metrics.treeRowHeight)
				.tag(SidebarNode.mount(mount.id))
			}
		}
	}

	@ViewBuilder
	private var serialGroup: some View {
		let ports = (vm.consolePorts ?? []) + (vm.uartPorts ?? [])
		group(.group("Serial"), symbol: MachmanSymbols.serialUart, title: "Serial",
			count: ports.count) {
			ForEach(ports) { port in
				serialRow(port)
			}
		}
	}

	private func serialRow(_ port: SerialPortInfo) -> some View {
		let ref = SerialPortRef(port)
		let open = sessions.isOpen(vm: vm.name, ref: ref)
		let gated = port.unavailable != nil
		let enabled = port.enabled ?? true
		return HStack(spacing: 6) {
			Image(systemName: port.kind == .console
				? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
				.font(.system(size: theme.metrics.iconSize))
			Text(port.guestDevice)
			Spacer()
			if gated {
				Image(systemName: MachmanSymbols.warning)
					.font(.system(size: 10))
					.foregroundStyle(MachmanColors.warning)
					.help(port.unavailable?.message ?? "Unavailable on this host")
			}
			if open {
				Circle().fill(MachmanColors.connected)
					.frame(width: 5, height: 5)
					.help("Terminal open")
			}
		}
		.opacity(!enabled ? MachmanColors.inactiveEntryOpacity
			: (gated ? MachmanColors.dimmedRowOpacity : 1))
		.frame(height: theme.metrics.treeRowHeight)
		.tag(SidebarNode.serial(ref))
		// Interim menu (full spec menus come with the context-menu slice): the old port
		// row's actions survive the list swap.
		.contextMenu {
			Button("Open") { openTerminal(ref) }
			Button("Close") { sessions.closeTab(vm: vm.name, ref: ref) }
				.disabled(!open)
			Button("Properties") {
				openTerminal(ref)
				viewModel.showInfoPanel = true
			}
		}
	}

	// Guest devices from the engine's assembly. Configurable kinds (inspector-backed) are
	// selectable; the rest are dimmed with a Remove-only menu. A host-gated device
	// (Rosetta not installed, nested unsupported) carries the warning + reason.
	@ViewBuilder
	private var deviceGroup: some View {
		let devices = vm.devices ?? []
		group(.group("Devices"), symbol: MachmanSymbols.deviceGroup, title: "Devices",
			count: devices.count) {
			ForEach(devices) { device in
				if device.kind.isConfigurable {
					deviceRow(device)
						.tag(SidebarNode.device(device.kind))
				} else {
					deviceRow(device)
						.opacity(MachmanColors.dimmedRowOpacity)
						.contextMenu {
							Button("Remove", role: .destructive) {
								viewModel.removeDevice(vm.name, kind: device.kind)
							}
						}
				}
			}
		}
	}

	private func deviceRow(_ device: DeviceInfo) -> some View {
		HStack(spacing: 6) {
			Image(systemName: device.kind.displaySymbol)
				.font(.system(size: theme.metrics.iconSize))
			Text(device.kind.displayLabel)
				.lineLimit(1)
			Spacer()
			if let gate = device.unavailable {
				Image(systemName: MachmanSymbols.warning)
					.font(.system(size: 10))
					.foregroundStyle(MachmanColors.warning)
					.help(gate.message)
			}
		}
		.opacity(device.enabled ? 1 : MachmanColors.inactiveEntryOpacity)
		.frame(height: theme.metrics.treeRowHeight)
	}

	// MARK: - Group scaffold

	// Group parents are dimmed and NOT selectable (no tag — selection skips them); their
	// add/paste actions arrive with the context-menu slice.
	private func group<Content: View>(
		_ node: SidebarNode, symbol: String, title: String, count: Int,
		@ViewBuilder content: @escaping () -> Content
	) -> some View {
		DisclosureGroup(isExpanded: groupBinding(node)) {
			content()
		} label: {
			HStack(spacing: 6) {
				Image(systemName: symbol)
					.font(.system(size: theme.metrics.iconSize))
					.foregroundStyle(.secondary)
				Text(title).fontWeight(.medium)
				Spacer()
				Text("\(count)")
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.monospacedDigit()
			}
			.frame(height: theme.metrics.treeRowHeight)
		}
		.opacity(MachmanColors.dimmedRowOpacity)
	}

	private func groupBinding(_ node: SidebarNode) -> Binding<Bool> {
		Binding(
			get: { expanded.contains(node) },
			set: { if $0 { expanded.insert(node) } else { expanded.remove(node) } })
	}

	// MARK: - Behaviour

	// Spec mapping: VM root → config tab, serial → terminal tab (never for disabled or
	// host-gated ports); entries → inspector once S6 lands.
	private func openNode(_ node: SidebarNode) {
		switch node {
		case .vmRoot:
			sessions.setActive(.config, for: vm.name)
		case .serial(let ref):
			let ports = (vm.consolePorts ?? []) + (vm.uartPorts ?? [])
			guard let port = ports.first(where: { SerialPortRef($0) == ref }),
				port.unavailable == nil, port.enabled ?? true else { return }
			openTerminal(ref)
		default:
			break
		}
	}

	private func openTerminal(_ ref: SerialPortRef) {
		// Instant: just record the tab. The container builds + connects the terminal lazily.
		sessions.openTab(vm: vm.name, ref: ref)
	}

	// MARK: - Helpers

	private static func symbol(for type: DiskType) -> String {
		switch type {
		case .storage: return MachmanSymbols.diskStorage
		case .image: return MachmanSymbols.diskImage
		case .iso: return MachmanSymbols.diskISO
		}
	}

	private static func lastComponent(_ path: String?) -> String {
		path.map { ($0 as NSString).lastPathComponent } ?? "disk"
	}

	private static func abbreviate(_ path: String) -> String {
		(path as NSString).abbreviatingWithTildeInPath
	}
}
