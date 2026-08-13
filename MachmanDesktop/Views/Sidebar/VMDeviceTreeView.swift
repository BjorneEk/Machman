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
import AppKit
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
	let profiles: TerminalProfileStore
	let vm: VMInfo
	@State private var treeSelection: Set<SidebarNode> = []
	@State private var renamingRoot = false
	@State private var filter = ""
	@State private var expanded: Set<SidebarNode> = [
		.group("Disks"), .group("Mounts"), .group("Serial"), .group("Devices"),
		.group("Kernel"), .group("Initramfs"),
	]
	@Environment(\.machmanTheme) private var theme

	var body: some View {
		VStack(spacing: 0) {
			filterField
			treeList
		}
	}

	private var filterField: some View {
		HStack(spacing: 5) {
			Image(systemName: MachmanSymbols.search)
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
			TextField("Filter devices", text: $filter)
				.textFieldStyle(.plain)
				.font(.callout)
			if !filter.isEmpty {
				IconButton(symbol: MachmanSymbols.closeTab, tooltip: "Clear",
					font: .caption, flat: true) { filter = "" }
			}
		}
		.padding(.horizontal, 7)
		.padding(.vertical, 4)
		.background(RoundedRectangle(cornerRadius: 5, style: .continuous)
			.fill(Color.primary.opacity(0.05)))
		.padding(.horizontal, 10)
		.padding(.top, 8)
	}

	// Rows filter on what they show; group counts keep the real totals.
	private func matches(_ candidates: String?...) -> Bool {
		filter.isEmpty || candidates.contains {
			$0?.localizedCaseInsensitiveContains(filter) == true
		}
	}

	private var treeList: some View {
		List(selection: $treeSelection) {
			vmRootRow
			diskGroup
			mountGroup
			serialGroup
			deviceGroup
			if showsKernelSections {
				kernelGroup(role: .kernel, title: "Kernel")
				kernelGroup(role: .initramfs, title: "Initramfs")
			}
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
		// Finder drop anywhere on the tree: folders become mounts, files ask
		// copy-or-reference (same funnel as the picker and paste).
		.dropDestination(for: URL.self) { urls, _ in
			AddFlows.handleFileURLs(urls, viewModel: viewModel, vm: vm.name)
		}
	}

	// MARK: - Rows

	private var vmRootRow: some View {
		HStack(spacing: 6) {
			StatusDot(state: vm.state, size: 8)
			if renamingRoot {
				RenameField(initial: vm.name) { newName in
					renamingRoot = false
					commitRename(to: newName)
				} cancel: {
					renamingRoot = false
				}
			} else {
				Text(vm.name).fontWeight(.semibold)
			}
			if vm.safeRun == true { SafeBadge(compact: true) }
			Spacer()
			BootBadge(mode: vm.boot.mode, size: 9)
		}
		.frame(height: theme.metrics.treeRowHeight)
		.tag(SidebarNode.vmRoot)
		.contextMenu {
			Button("Rename") { renamingRoot = true }
			Button("Paste") {
				_ = AddFlows.handleFileURLs(
					AddFlows.pasteboardFileURLs(), viewModel: viewModel, vm: vm.name)
			}
			.disabled(AddFlows.pasteboardFileURLs().isEmpty)
			Divider()
			Button("Delete VM…", role: .destructive) { viewModel.deleteVM(vm) }
		}
	}

	// In-place rename: Return commits (Esc cancels), so no extra confirmation dialog.
	private func commitRename(to newName: String) {
		let old = vm.name
		guard !newName.isEmpty, newName != old else { return }
		guard !viewModel.hasVM(newName) else {
			viewModel.present(
				message: "A VM named '\(newName)' already exists.",
				while: "Renaming \(old)")
			return
		}
		Task {
			if await viewModel.rename(from: old, to: newName) {
				profiles.renameVM(from: old, to: newName)
				viewModel.log(message: "Renamed \(old) to \(newName)")
			}
		}
	}

	@ViewBuilder
	private var diskGroup: some View {
		let disks = vm.disks
		group(.group("Disks"), symbol: MachmanSymbols.diskName, title: "Disks",
			count: disks.count, menu: {
				Button("Add Existing Disk…") {
					AddFlows.chooseExistingDisk(viewModel: viewModel, vm: vm.name)
				}
			}) {
			ForEach(disks.filter { matches($0.name, $0.path) }) { disk in
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
				.contextMenu { diskMenu(disk) }
			}
		}
	}

	@ViewBuilder
	private func diskMenu(_ disk: DiskInfo) -> some View {
		if let path = disk.path {
			Button("Copy Path") { Self.copyToPasteboard(path) }
			Button("Show in Finder") { Self.revealInFinder(path) }
			Divider()
		}
		Button(disk.isEnabled ? "Disable" : "Enable") {
			viewModel.setEnabled(vm.name, disks: [disk.id: !disk.isEnabled])
		}
		if disk.owned == false {
			Button("Promote to Owned…") { viewModel.promoteDisk(vm.name, diskID: disk.id) }
		}
		Divider()
		Button(disk.owned == true ? "Delete…" : "Remove…", role: .destructive) {
			if disk.owned == true {
				guard VMListViewModel.confirmDialog(
					message: "Delete disk \(disk.name ?? disk.id)?",
					informativeText: "The backing file belongs to \(vm.name) and will be "
						+ "deleted with it.")
				else { return }
			}
			viewModel.removeDisk(vm.name, diskID: disk.id)
		}
	}

	@ViewBuilder
	private var mountGroup: some View {
		let mounts = vm.mounts
		group(.group("Mounts"), symbol: MachmanSymbols.mount, title: "Mounts",
			count: mounts.count, menu: {
				Button("Add Mount Folder…") {
					AddFlows.chooseMountFolder(viewModel: viewModel, vm: vm.name)
				}
			}) {
			ForEach(mounts.filter { matches($0.path, $0.tag) }) { mount in
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
				.contextMenu {
					Button("Copy Path") { Self.copyToPasteboard(mount.path) }
					Button("Show in Finder") { Self.revealInFinder(mount.path) }
					Divider()
					Button(mount.isEnabled ? "Disable" : "Enable") {
						viewModel.setEnabled(vm.name, mounts: [mount.id: !mount.isEnabled])
					}
					Divider()
					Button("Remove…", role: .destructive) {
						viewModel.removeMount(vm.name, mountID: mount.id)
					}
				}
			}
		}
	}

	@ViewBuilder
	private var serialGroup: some View {
		let ports = (vm.consolePorts ?? []) + (vm.uartPorts ?? [])
		group(.group("Serial"), symbol: MachmanSymbols.serialUart, title: "Serial",
			count: ports.count) {
			ForEach(ports.filter { matches($0.guestDevice) }) { port in
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
		.contextMenu { serialMenu(port, ref: ref, open: open, gated: gated, enabled: enabled) }
	}

	// HIG: hide (don't dim) unavailable actions — a host-gated or disabled port has no
	// terminal and no socket.
	@ViewBuilder
	private func serialMenu(
		_ port: SerialPortInfo, ref: SerialPortRef, open: Bool, gated: Bool, enabled: Bool
	) -> some View {
		if !gated && enabled {
			if open {
				Button("Close Terminal (disconnect)") {
					sessions.closeTab(vm: vm.name, ref: ref)
				}
			} else {
				Button("Open Terminal (connect)") { openTerminal(ref) }
			}
			Button("Properties") {
				openTerminal(ref)
				viewModel.showInfoPanel = true
			}
			if let socket = port.socketPath {
				Button("Copy Socket Path") { Self.copyToPasteboard(socket) }
			}
			Divider()
		}
		Button(enabled ? "Disable" : "Enable") {
			let change = [String(port.index): !enabled]
			if port.kind == .console {
				viewModel.setEnabled(vm.name, console: change)
			} else {
				viewModel.setEnabled(vm.name, uart: change)
			}
		}
		// The remove APIs pop the highest index of a kind, so only that port offers Remove.
		if isLastOfKind(port) {
			Button("Remove…", role: .destructive) {
				if port.kind == .console {
					viewModel.removeConsolePort(vm.name)
				} else {
					viewModel.removeUartPort(vm.name)
				}
			}
		}
	}

	private func isLastOfKind(_ port: SerialPortInfo) -> Bool {
		let peers = port.kind == .console ? (vm.consolePorts ?? []) : (vm.uartPorts ?? [])
		return port.index == peers.map(\.index).max()
	}

	// Guest devices from the engine's assembly. Configurable kinds (inspector-backed) are
	// selectable; the rest are dimmed with a Remove-only menu. A host-gated device
	// (Rosetta not installed, nested unsupported) carries the warning + reason.
	@ViewBuilder
	private var deviceGroup: some View {
		let devices = vm.devices ?? []
		group(.group("Devices"), symbol: MachmanSymbols.deviceGroup, title: "Devices",
			count: devices.count) {
			ForEach(devices.filter { matches($0.kind.displayLabel) }) { device in
				if device.kind.isConfigurable {
					deviceRow(device)
						.tag(SidebarNode.device(device.kind))
						.contextMenu { deviceMenu(device) }
				} else {
					deviceRow(device)
						.opacity(MachmanColors.dimmedRowOpacity)
						.contextMenu { deviceMenu(device) }
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

	@ViewBuilder
	private func deviceMenu(_ device: DeviceInfo) -> some View {
		Button(device.enabled ? "Disable" : "Enable") {
			var updated = device
			updated.enabled = !device.enabled
			viewModel.updateDevice(vm.name, device: updated)
		}
		Button("Remove", role: .destructive) {
			viewModel.removeDevice(vm.name, kind: device.kind)
		}
	}

	// MARK: - Kernel / Initramfs

	// Kernel sections appear once kernel boot is (or was) configured — the draft survives
	// toggling back to EFI, shown parked (dimmed) until kernel boot is on again.
	private var showsKernelSections: Bool {
		vm.boot.mode != .macOS
			&& (vm.boot.kernel != nil || !(vm.boot.ownedKernels ?? []).isEmpty)
	}

	private var kernelSectionParked: Bool { vm.boot.mode != .linuxKernel }

	private struct KernelEntry: Identifiable {
		let id: String        // absolute path (OwnedKernelFile.id)
		let label: String     // tag, or file name for external references
		let owned: Bool
		let active: Bool
	}

	// Owned files of the role, plus the active settings path when it points outside the
	// owned set (an external reference — promotable).
	private func kernelEntries(role: KernelRole) -> [KernelEntry] {
		let owned = (vm.boot.ownedKernels ?? []).filter { $0.role == role }
		let activePath = role == .kernel
			? vm.boot.kernel?.kernelPath : vm.boot.kernel?.initrdPath
		var entries = owned.map {
			KernelEntry(id: $0.path, label: $0.tag, owned: true, active: $0.path == activePath)
		}
		if let activePath, !activePath.isEmpty,
			!owned.contains(where: { $0.path == activePath }) {
			entries.append(KernelEntry(
				id: activePath, label: (activePath as NSString).lastPathComponent,
				owned: false, active: true))
		}
		return entries
	}

	// The VM cannot start kernel boot without a kernel path.
	private var missingKernelWarning: Bool {
		vm.boot.mode == .linuxKernel && (vm.boot.kernel?.kernelPath ?? "").isEmpty
	}

	@ViewBuilder
	private func kernelGroup(role: KernelRole, title: String) -> some View {
		let entries = kernelEntries(role: role)
		let dg = DisclosureGroup(isExpanded: groupBinding(.group(title))) {
			ForEach(entries.filter { matches($0.label) }) { file in
				HStack(spacing: 6) {
					if role == .kernel {
						TuxIcon(size: theme.metrics.iconSize + 1)
					} else {
						Image(systemName: MachmanSymbols.initramfs)
							.font(.system(size: theme.metrics.iconSize))
					}
					Text(file.label)
						.fontWeight(file.active ? .medium : .regular)
						.truncationMode(.middle)
						.lineLimit(1)
						.help(file.id)
					Spacer()
					if !file.owned {
						Image(systemName: MachmanSymbols.externalReference)
							.font(.system(size: 9))
							.foregroundStyle(.tertiary)
							.help("External file — promote to copy it into the VM")
					}
					if file.active {
						Image(systemName: MachmanSymbols.activeEntry)
							.font(.system(size: 10))
							.foregroundStyle(MachmanColors.activeEntry)
							.help("Active")
					}
				}
				.opacity(file.active ? 1 : MachmanColors.inactiveEntryOpacity)
				.frame(height: theme.metrics.treeRowHeight)
				.tag(role == .kernel
					? SidebarNode.kernel(file.id) : SidebarNode.initramfs(file.id))
				.contextMenu { kernelEntryMenu(file, role: role) }
			}
		} label: {
			HStack(spacing: 6) {
				if role == .kernel {
					TuxIcon(size: theme.metrics.iconSize + 1)
				} else {
					Image(systemName: MachmanSymbols.initramfs)
						.font(.system(size: theme.metrics.iconSize))
				}
				Text(title).fontWeight(.medium)
				Spacer()
				if role == .kernel && missingKernelWarning {
					Image(systemName: MachmanSymbols.warning)
						.font(.system(size: 10))
						.foregroundStyle(MachmanColors.warning)
						.help("No kernel selected — the VM cannot start")
				}
			}
			.frame(height: theme.metrics.treeRowHeight)
			.contextMenu {
				Button("Add From Disk…") {
					AddFlows.chooseKernelFile(viewModel: viewModel, vm: vm.name, role: role)
				}
			}
		}
		// Kernel parent is selectable (it has an inspector); the initramfs parent is a dim
		// unselectable group like the others. Both park (extra dim) while kernel boot is off.
		if role == .kernel {
			dg
				.tag(SidebarNode.group("Kernel"))
				.opacity(kernelSectionParked ? 0.45 : 1)
		} else {
			dg.opacity(kernelSectionParked ? 0.45 : MachmanColors.dimmedRowOpacity)
		}
	}

	@ViewBuilder
	private func kernelEntryMenu(_ file: KernelEntry, role: KernelRole) -> some View {
		if file.active {
			Button("Deselect") { setActiveKernelPath(nil, role: role) }
		} else {
			Button("Select") { setActiveKernelPath(file.id, role: role) }
		}
		Button("Copy Path") { Self.copyToPasteboard(file.id) }
		Button("Show in Finder") { Self.revealInFinder(file.id) }
		if !file.owned {
			Button("Promote to Owned…") {
				viewModel.promoteKernel(
					vm.name, role: role, sourcePath: file.id,
					tag: URL(fileURLWithPath: file.id)
						.deletingPathExtension().lastPathComponent)
			}
		}
		if file.owned {
			Divider()
			Button("Delete…", role: .destructive) {
				viewModel.deleteKernel(vm.name, path: file.id)
			}
		}
	}

	// Select/deselect rewires the kernel-boot draft: the settings survive as a draft even
	// while the mode is EFI, so this never toggles the boot mode itself.
	private func setActiveKernelPath(_ path: String?, role: KernelRole) {
		var settings = vm.boot.kernel
			?? KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "")
		switch role {
		case .kernel: settings.kernelPath = path ?? ""
		case .initramfs: settings.initrdPath = path
		}
		viewModel.updateKernelSettings(vm.name, settings)
	}

	// MARK: - Group scaffold

	// Group parents are dimmed and NOT selectable (no tag — selection skips them); their
	// add actions live in a row-level context menu on the label.
	private func group<Content: View, MenuItems: View>(
		_ node: SidebarNode, symbol: String, title: String, count: Int,
		@ViewBuilder menu: @escaping () -> MenuItems = { EmptyView() },
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
			.contextMenu { menu() }
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

	private static func copyToPasteboard(_ value: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(value, forType: .string)
	}

	private static func revealInFinder(_ path: String) {
		NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
	}
}
