//
//  VMDeviceTreeView.swift
//  MachmanDesktopUI
//
//  The sidebar device tree (1.0.4 UI): the selected VM as root with Disks / Mounts / Serial /
//  SSH / Installers / Devices / Kernel / Initramfs groups. A group without rows hides unless
//  the tree is where its things are added, and a filter hides every group without a match
//  (TreeSection, N1). Group parents are dimmed and unselectable — entry rows carry the
//  interaction: dim when disabled, link badge on referenced files, warning + no tab for
//  host-gated uarts, live dot on open terminals. VM switching lives in the toolbar picker.
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct VMDeviceTreeView: View {
	@ObservedObject var viewModel: VMListViewModel
	@ObservedObject var sessions: TerminalSessions
	@ObservedObject var canvases: CanvasStateStore
	// Torn-off windows are open tabs too — the tree observes them so a detached terminal
	// keeps its row (and its way back). The view model's registry: the app's shared one, a
	// scene's own in renders.
	@ObservedObject private var tornTabs: TornTabRegistry
	// What Paste can take (H25): re-read when the pasteboard changes, not on every render.
	@ObservedObject private var pasteboard: PasteboardWatch
	let profiles: TerminalProfileStore
	let vm: VMInfo
	@State private var renamingRoot = false
	// Entry being renamed in place (owned storage disks + owned kernel files).
	@State private var renamingNode: SidebarNode?
	// A drag hovering a section: drives the would-be preview row + copy/forbidden cursor.
	@State private var dragPreview: TreeDragPreview?
	// The List's selection buffer: macOS sidebar Lists write their selection binding
	// MID-view-update, so binding a @Published set directly warns ("Publishing changes
	// from within view updates") on every click. The @Published mirror syncs deferred.
	@State private var localSelection: Set<SidebarNode> = []
	// Expiry watchdog: dropExited is not guaranteed on session cancel, so every delegate
	// touch bumps the generation and the preview clears after two quiet seconds.
	@State private var dragGeneration = 0
	@State private var dragWatchdog: Task<Void, Never>?
	@State private var filter = ""
	@State private var expanded: Set<SidebarNode> = [
		.group("Disks"), .group("Mounts"), .group("Serial"), .group("SSH"),
		.group("Installers"), .group("Devices"), .group("Kernel"), .group("Initramfs"),
	]
	@Environment(\.machmanTheme) private var theme
	@Environment(\.openWindow) private var openWindow

	// `dragPreview` starts the tree with a drag already hovering, `filter` with text in the
	// filter field (render scenes); `pasteboard` defaults to the general pasteboard's watch.
	init(
		viewModel: VMListViewModel, sessions: TerminalSessions, canvases: CanvasStateStore,
		profiles: TerminalProfileStore, vm: VMInfo, dragPreview: TreeDragPreview? = nil,
		filter: String = "", pasteboard: PasteboardWatch? = nil
	) {
		self.viewModel = viewModel
		_tornTabs = ObservedObject(wrappedValue: viewModel.tornTabs)
		_pasteboard = ObservedObject(wrappedValue: pasteboard ?? .general)
		self.sessions = sessions
		self.canvases = canvases
		self.profiles = profiles
		self.vm = vm
		_dragPreview = State(initialValue: dragPreview)
		_filter = State(initialValue: filter)
	}

	var body: some View {
		VStack(spacing: 0) {
			filterField
			treeList
		}
	}

	// What the sections share, over this view's stores and state (TreeContext).
	private var context: TreeContext {
		TreeContext(
			viewModel: viewModel, sessions: sessions, canvases: canvases, tornTabs: tornTabs,
			pasteboard: pasteboard, vm: vm, filter: filter, renamingRoot: $renamingRoot,
			renamingNode: $renamingNode, dragPreview: $dragPreview, expanded: $expanded,
			dragTouched: { dragGeneration &+= 1 }, openWindow: openWindow)
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

	private var treeList: some View {
		let ctx = context
		return List(selection: $localSelection) {
			vmRootRow(ctx)
			diskGroup(ctx)
			mountGroup(ctx)
			serialGroup(ctx)
			sshGroup(ctx)
			installerGroup(ctx)
			deviceGroup(ctx)
			if vm.showsKernelSections {
				kernelGroup(ctx, role: .kernel)
				kernelGroup(ctx, role: .initramfs)
			}
		}
		.listStyle(.sidebar)
		.environment(\.defaultMinListRowHeight, theme.metrics.treeRowHeight)
		.font(.system(size: theme.metrics.rowFontSize))
		// A remount (VM switch, reconnect) starts from the surviving published selection.
		.onAppear { localSelection = viewModel.treeSelection }
		// The mirror runs DEFERRED — the click lands mid-update. Selecting never opens
		// (T7): arrow keys, type-select and ⌘/⇧-clicks only move the selection; a plain
		// click (the rows' tap gesture) or Return opens.
		.onChange(of: localSelection) {
			let selection = localSelection
			DispatchQueue.main.async { [weak viewModel] in
				viewModel?.treeSelectionChanged(selection)
			}
		}
		.onKeyPress(.return) {
			guard !renamingRoot, renamingNode == nil, localSelection.count == 1,
				let node = localSelection.first,
				VMListViewModel.opensOnClick(node) else { return .ignored }
			ctx.open(node)
			return .handled
		}
		// Programmatic selection (row menus, batch actions) flows back into the List.
		.onChange(of: viewModel.treeSelection) {
			if localSelection != viewModel.treeSelection {
				localSelection = viewModel.treeSelection
			}
		}
		// The tree shows ONE VM; stale nodes must not survive into another VM's tree.
		.onChange(of: vm.name) {
			localSelection = []
			dragPreview = nil
			DispatchQueue.main.async { [weak viewModel] in
				viewModel?.treeSelection = []
			}
		}
		.onChange(of: dragGeneration) {
			dragWatchdog?.cancel()
			dragWatchdog = Task {
				try? await Task.sleep(for: .seconds(2))
				guard !Task.isCancelled else { return }
				dragPreview = nil
			}
		}
		// Finder drop anywhere on the tree: folders become mounts, files ask
		// copy-or-reference (same funnel as the picker and paste).
		.dropDestination(for: URL.self) { urls, _ in
			AddFlows.handleFileURLs(urls, viewModel: viewModel, vm: vm.name)
		}
		// Right-click anywhere in the tree (rows keep their own menus): paste the
		// clipboard's entities/files into this VM.
		.contextMenu {
			Button("Paste") { ctx.pasteAnything() }
				.disabled(!pasteboard.snapshot.canPasteAnything)
		}
	}

	// MARK: - Rows

	private func vmRootRow(_ ctx: TreeContext) -> some View {
		HStack(spacing: 6) {
			VMStatusDot(vm: vm, size: 8)
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
		.treeRow(.vmRoot, onClick: { ctx.clicked(.vmRoot) }) { ctx.rootMenu() }
	}

	// In-place rename: Return commits (Esc cancels), so no extra confirmation dialog.
	private func commitRename(to newName: String) {
		viewModel.requestRename(vm, to: newName, profiles: profiles)
	}

	@ViewBuilder
	private func diskGroup(_ ctx: TreeContext) -> some View {
		let disks = ctx.sectionRows(.disks, ctx.vm.disks) { ctx.matches($0.name, $0.path) }
		if ctx.shows(.disks, rows: disks.count) {
			TreeGroup(.group("Disks"), symbol: MachmanSymbols.diskName, title: "Disks",
				count: ctx.vm.disks.count, isExpanded: ctx.groupBinding(.group("Disks")), menu: {
					Button("Add Existing Disk…") {
						AddFlows.chooseExistingDisk(viewModel: ctx.viewModel, vm: ctx.vm.name)
					}
					Button("Paste") { ctx.paste(into: .disks) }
						.disabled(!ctx.pasteboard.snapshot.canPaste(into: .disks))
				}) {
				ForEach(disks) { disk in
					HStack(spacing: 6) {
						Image(systemName: Self.symbol(for: disk.type))
							.font(.system(size: theme.metrics.iconSize))
							.foregroundStyle(disk.owned == false ? Color.secondary : Color.primary)
						if ctx.renamingNode == .disk(disk.id) {
							RenameField(initial: disk.name ?? "") { newName in
								ctx.renamingNode = nil
								ctx.viewModel.renameDisk(
									ctx.vm.name, diskID: disk.id, newName: newName)
							} cancel: {
								ctx.renamingNode = nil
							}
						} else {
							Text(disk.name ?? Self.lastComponent(disk.path))
								.truncationMode(.middle)
								.lineLimit(1)
						}
						Spacer()
						if disk.owned == false {
							Image(systemName: MachmanSymbols.externalReference)
								.font(.system(size: 9))
								.foregroundStyle(.tertiary)
								.help("Referenced — lives outside the VM directory")
						}
					}
					.treeRow(
						.disk(disk.id),
						opacity: disk.isEnabled ? 1 : MachmanColors.inactiveEntryOpacity
					) { ctx.diskMenu(disk) }
				}
				ctx.dropPreview(in: .disks, icon: MachmanSymbols.diskStorage)
			}
			.onDrop(of: [.fileURL], delegate: ctx.dropDelegate(.disks))
		}
	}

	@ViewBuilder
	private func mountGroup(_ ctx: TreeContext) -> some View {
		let mounts = ctx.sectionRows(.mounts, ctx.vm.mounts) { ctx.matches($0.path, $0.tag) }
		if ctx.shows(.mounts, rows: mounts.count) {
			TreeGroup(.group("Mounts"), symbol: MachmanSymbols.mount, title: "Mounts",
				count: ctx.vm.mounts.count, isExpanded: ctx.groupBinding(.group("Mounts")),
				menu: {
					Button("Add Mount Folder…") {
						AddFlows.chooseMountFolder(viewModel: ctx.viewModel, vm: ctx.vm.name)
					}
					Button("Paste") { ctx.paste(into: .mounts) }
						.disabled(!ctx.pasteboard.snapshot.canPaste(into: .mounts))
				}) {
				ForEach(mounts) { mount in
					HStack(spacing: 6) {
						Image(systemName: MachmanSymbols.mount)
							.font(.system(size: theme.metrics.iconSize))
						Text(Self.abbreviate(mount.path))
							.truncationMode(.middle)
							.lineLimit(1)
							.help("\(mount.path) — guest tag “\(mount.tag)”")
						Spacer()
						// Trailing badges (the disks' externalReference pattern): how the
						// mount travels, and whether the guest mounts it at boot.
						if mount.effectiveKind == MountKind.sshfs {
							Image(systemName: MachmanSymbols.mountSSHFS)
								.font(.system(size: 9))
								.foregroundStyle(.tertiary)
								.help("sshfs — the guest mounts this over its SSH link")
						}
						if mount.automounted == true {
							Image(systemName: MachmanSymbols.automounted)
								.font(.system(size: 9))
								.foregroundStyle(.tertiary)
								.help(mount.automountedAt.map { "Mounts at boot at \($0)" }
									?? "Mounted at boot by Guest Setup")
						}
					}
					.treeRow(
						.mount(mount.id),
						opacity: mount.isEnabled ? 1 : MachmanColors.inactiveEntryOpacity
					) { ctx.mountMenu(mount) }
				}
				ctx.dropPreview(in: .mounts, icon: MachmanSymbols.mount)
			}
			.onDrop(of: [.fileURL], delegate: ctx.dropDelegate(.mounts))
		}
	}

	@ViewBuilder
	private func serialGroup(_ ctx: TreeContext) -> some View {
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
					serialRow(ctx, port)
				}
			}
		}
	}

	private func serialRow(_ ctx: TreeContext, _ port: SerialPortInfo) -> some View {
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

	// Ephemeral SSH sessions, once the guest has reported a user: the section title IS
	// the command, the + opens a fresh session tab, and the open sessions are the
	// children — no devices behind them, nothing persists.
	// Present as soon as SSH is part of this VM — the installer attached, or state on
	// file — because this section is where SSH is set up, not just where sessions live.
	@ViewBuilder
	private func sshGroup(_ ctx: TreeContext) -> some View {
		if ctx.vm.ssh?.configured == true {
			// Canvas tabs AND live torn-off windows: a detached session is still open, and
			// dropping it from this list would leave no way back to its window.
			let open = ctx.viewModel.openSSHSessions(vm: ctx.vm.name)
			let rows = ctx.sectionRows(.ssh, open) {
				ctx.matches(ctx.sessions.sshSessionName(vm: ctx.vm.name, ref: $0))
			}
			if ctx.shows(.ssh, rows: rows.count) {
				TreeGroup(.group("SSH"), symbol: MachmanSymbols.deviceSSHSetup,
					title: "SSH", count: open.count, selectable: true,
					isExpanded: ctx.groupBinding(.group("SSH")), menu: {
					// The + accessory's reliable twin — List group labels can swallow clicks.
					Button("New SSH Session") { openSSHSession(ctx) }
						.disabled(!sshSessionReady(ctx.vm))
					if sshUnreachable(ctx.vm) || sshWaiting(ctx.vm) {
						Button("Check Connection") { ctx.viewModel.refreshSSH(ctx.vm.name) }
					}
				}, accessory: { sshSessionButton(ctx) }) {
					ForEach(rows) { ref in
						sshSessionRow(ctx, ref)
					}
				}
			}
		}
	}

	private func sshSessionRow(_ ctx: TreeContext, _ ref: SSHSessionRef) -> some View {
		let torn = ctx.isTorn(.ssh(ref))
		return HStack(spacing: 6) {
			Image(systemName: MachmanSymbols.tabTerminal)
				.font(.system(size: theme.metrics.iconSize))
			Text(ctx.sessions.sshSessionName(vm: ctx.vm.name, ref: ref))
				.lineLimit(1)
			Spacer()
			if torn {
				Image(systemName: MachmanSymbols.newWindow)
					.font(.system(size: 9))
					.foregroundStyle(.tertiary)
					.help("Open in its own window")
			}
			// theme.accentColor: List rows reset Color.accentColor to the system's (H20).
			Circle().fill(theme.accentColor)
				.frame(width: 5, height: 5)
				.help("Session open")
		}
		.treeRow(.sshSession(ref), onClick: { ctx.clicked(.sshSession(ref)) }) {
			ctx.sshSessionMenu(ref, torn: torn)
		}
	}

	// A session can only start once the guest's sshd actually answers — the daemon's
	// reachability, not just an address (which appears long before sshd is listening).
	private func sshSessionReady(_ vm: VMInfo) -> Bool {
		vm.state.isRunning && vm.ssh?.reachability == .ready
			&& SSHCommand.arguments(for: vm) != nil
	}

	private func sshUnreachable(_ vm: VMInfo) -> Bool {
		vm.state.isRunning && vm.ssh?.reachability == .unreachable
	}

	private func sshWaiting(_ vm: VMInfo) -> Bool {
		vm.state.isRunning && vm.ssh?.reachability == .waiting
	}

	// One control, three states: waiting on the guest, retry after giving up, or open a
	// session. The tooltip carries the reason, so the row itself stays quiet.
	@ViewBuilder
	private func sshSessionButton(_ ctx: TreeContext) -> some View {
		if sshWaiting(ctx.vm) {
			// No scaleEffect + fixed frame here: constraining a hosted AppKit
			// ProgressView to a size it also computes for itself makes it complain
			// ("maximum length … doesn't satisfy min <= max") on every layout pass.
			ProgressView()
				.controlSize(.small)
				.help("Waiting for sshd in the guest to answer…")
		} else if sshUnreachable(ctx.vm) {
			IconButton(symbol: MachmanSymbols.regenerate,
				tooltip: ctx.vm.ssh?.reachabilityDetail.map { "SSH: \($0) — try again" }
					?? "SSH did not answer — try again",
				font: .caption, flat: true) { ctx.viewModel.refreshSSH(ctx.vm.name) }
		} else {
			IconButton(symbol: MachmanSymbols.add,
				tooltip: sshSessionReady(ctx.vm)
					? "New SSH session tab"
					: "Sessions need the VM running and answering on port 22",
				font: .caption, flat: true) { openSSHSession(ctx) }
				.disabled(!sshSessionReady(ctx.vm))
		}
	}

	private func openSSHSession(_ ctx: TreeContext) {
		guard SSHCommand.arguments(for: ctx.vm) != nil else { return }
		let ref = SSHSessionRef(title: ctx.viewModel.nextSSHSessionTitle(vm: ctx.vm.name))
		ctx.mutateCanvas { $0.open(.ssh(ref)) }
	}

	// Installer devices (share-served guest-setup payloads): their own section — they
	// configure the guest rather than being hardware. Add actions live in the group's
	// context menu, the Disks convention.
	@ViewBuilder
	private func installerGroup(_ ctx: TreeContext) -> some View {
		let installers = (ctx.vm.devices ?? []).filter(\.kind.isInstaller)
		let rows = ctx.sectionRows(.installers, installers) { ctx.matches($0.kind.displayLabel) }
		// The unified Guest Setup (the legacy Console Login / SSH Setup kinds migrate to it).
		if ctx.shows(.installers, rows: rows.count) {
			TreeGroup(.group("Installers"), symbol: MachmanSymbols.installerGroup,
				title: "Installers", count: installers.count,
				isExpanded: ctx.groupBinding(.group("Installers")), menu: {
				if ctx.vm.canAddGuestSetup {
					Button("Add Guest Setup") {
						ctx.viewModel.addDevice(ctx.vm.name, kind: .guestSetup)
					}
				}
			}) {
				ForEach(rows) { device in
					deviceRow(ctx, device)
				}
			}
		}
	}

	// Guest devices from the engine's assembly. Every kind is selectable (kinds without
	// settings get the generic info inspector); disabled devices dim, and a host-gated one
	// (Rosetta not installed, nested unsupported) carries the warning + reason.
	@ViewBuilder
	private func deviceGroup(_ ctx: TreeContext) -> some View {
		// Installer kinds render under Installers instead.
		let devices = (ctx.vm.devices ?? []).filter { !$0.kind.isInstaller }
		let rows = ctx.sectionRows(.devices, devices) { ctx.matches($0.kind.displayLabel) }
		if ctx.shows(.devices, rows: rows.count) {
			TreeGroup(.group("Devices"), symbol: MachmanSymbols.deviceGroup, title: "Devices",
				count: devices.count, isExpanded: ctx.groupBinding(.group("Devices"))) {
				ForEach(rows) { device in
					deviceRow(ctx, device)
				}
			}
		}
	}

	private func deviceRow(_ ctx: TreeContext, _ device: DeviceInfo) -> some View {
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
		.treeRow(
			.device(device.kind),
			opacity: device.enabled ? 1 : MachmanColors.inactiveEntryOpacity
		) { ctx.deviceMenu(device) }
	}

	// MARK: - Kernel / Initramfs

	// The sections show once kernel boot is (or was) configured (VMInfo.showsKernelSections:
	// parked, dimmed, while kernel boot is off); their rows are VMInfo.kernelTreeEntries.

	// The VM cannot start kernel boot without a kernel path.
	private func missingKernelWarning(_ vm: VMInfo) -> Bool {
		vm.boot.mode == .linuxKernel && (vm.boot.kernel?.kernelPath ?? "").isEmpty
	}

	@ViewBuilder
	private func kernelGroup(_ ctx: TreeContext, role: KernelRole) -> some View {
		let section: TreeSection = role == .kernel ? .kernel : .initramfs
		let entries = ctx.sectionRows(section, ctx.vm.kernelTreeEntries(role: role)) {
			ctx.matches($0.label)
		}
		if ctx.shows(section, rows: entries.count) {
			kernelDisclosure(ctx, role: role, title: section.title, entries: entries)
		}
	}

	@ViewBuilder
	private func kernelDisclosure(
		_ ctx: TreeContext, role: KernelRole, title: String, entries: [KernelTreeEntry]
	) -> some View {
		// Kernel parent is selectable (it has an inspector); the initramfs parent is a dim
		// unselectable group like the others. Both park (extra dim) while kernel boot is off.
		TreeGroup(
			.group(title), title: title, count: nil, selectable: role == .kernel,
			parked: ctx.vm.kernelSectionParked, isExpanded: ctx.groupBinding(.group(title)),
			icon: {
				if role == .kernel {
					TuxIcon(size: theme.metrics.iconSize + 1)
				} else {
					Image(systemName: MachmanSymbols.initramfs)
						.font(.system(size: theme.metrics.iconSize))
				}
			},
			menu: {
				Button("Add From Disk…") {
					AddFlows.chooseKernelFile(
						viewModel: ctx.viewModel, vm: ctx.vm.name, role: role)
				}
				Button("Paste") { ctx.paste(into: .kernel(role)) }
					.disabled(!ctx.pasteboard.snapshot.canPaste(into: .kernel(role)))
			},
			accessory: {
				if role == .kernel && missingKernelWarning(ctx.vm) {
					Image(systemName: MachmanSymbols.warning)
						.font(.system(size: 10))
						.foregroundStyle(MachmanColors.warning)
						.help("No kernel selected — the VM cannot start")
				}
			}
		) {
			ForEach(entries) { file in
				HStack(spacing: 6) {
					if role == .kernel {
						TuxIcon(size: theme.metrics.iconSize + 1)
					} else {
						Image(systemName: MachmanSymbols.initramfs)
							.font(.system(size: theme.metrics.iconSize))
					}
					if ctx.renamingNode == (role == .kernel
						? SidebarNode.kernel(file.id) : SidebarNode.initramfs(file.id)) {
						RenameField(initial: file.label) { tag in
							ctx.renamingNode = nil
							ctx.viewModel.renameKernelTag(ctx.vm.name, path: file.id, tag: tag)
						} cancel: {
							ctx.renamingNode = nil
						}
					} else {
						Text(file.label)
							.fontWeight(file.active ? .medium : .regular)
							.truncationMode(.middle)
							.lineLimit(1)
							.help(file.id)
					}
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
							.foregroundStyle(theme.accentColor)
							.help("Active")
					}
				}
				.treeRow(
					role == .kernel ? .kernel(file.id) : .initramfs(file.id),
					opacity: file.active ? 1 : MachmanColors.inactiveEntryOpacity
				) { ctx.kernelEntryMenu(file, role: role) }
			}
			ctx.dropPreview(
				in: .kernel(role),
				icon: role == .kernel ? MachmanSymbols.kernelFile : MachmanSymbols.initramfs)
		}
		.onDrop(of: [.fileURL], delegate: ctx.dropDelegate(.kernel(role)))
	}

	// MARK: - Helpers

	private static func symbol(for type: DiskType) -> String {
		switch type {
		case .storage: return MachmanSymbols.diskStorage
		case .image: return MachmanSymbols.diskImage
		case .iso: return MachmanSymbols.diskISO
		case .unknown: return MachmanSymbols.help
		}
	}

	private static func lastComponent(_ path: String?) -> String {
		path.map { ($0 as NSString).lastPathComponent } ?? "disk"
	}

	private static func abbreviate(_ path: String) -> String {
		(path as NSString).abbreviatingWithTildeInPath
	}
}
