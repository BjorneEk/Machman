//
//  VMDeviceTreeView.swift
//  MachmanDesktopUI
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
import MachmanDesktopCore

struct VMDeviceTreeView: View {
	@ObservedObject var viewModel: VMListViewModel
	@ObservedObject var sessions: TerminalSessions
	@ObservedObject var canvases: CanvasStateStore
	// Torn-off windows are open tabs too — the tree observes them so a detached terminal
	// keeps its row (and its way back).
	@ObservedObject private var tornTabs = TornTabRegistry.shared
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
	@Environment(\.dismissWindow) private var dismissWindow

	// `dragPreview` starts the tree with a drag already hovering (render scenes).
	init(
		viewModel: VMListViewModel, sessions: TerminalSessions, canvases: CanvasStateStore,
		profiles: TerminalProfileStore, vm: VMInfo, dragPreview: TreeDragPreview? = nil
	) {
		self.viewModel = viewModel
		self.sessions = sessions
		self.canvases = canvases
		self.profiles = profiles
		self.vm = vm
		_dragPreview = State(initialValue: dragPreview)
	}

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
		List(selection: $localSelection) {
			vmRootRow
			diskGroup
			mountGroup
			serialGroup
			sshGroup
			installerGroup
			deviceGroup
			if showsKernelSections {
				kernelGroup(role: .kernel, title: "Kernel")
				kernelGroup(role: .initramfs, title: "Initramfs")
			}
		}
		.listStyle(.sidebar)
		.environment(\.defaultMinListRowHeight, theme.metrics.treeRowHeight)
		.font(.system(size: theme.metrics.rowFontSize))
		// A remount (VM switch, reconnect) starts from the surviving published selection.
		.onAppear { localSelection = viewModel.treeSelection }
		// Mirror + open side effects run DEFERRED — the click lands mid-update.
		.onChange(of: localSelection) {
			let selection = localSelection
			DispatchQueue.main.async { [weak viewModel] in
				guard let viewModel, viewModel.treeSelection != selection else { return }
				viewModel.treeSelection = selection
				if selection.count == 1, let node = selection.first {
					openNode(node)
				}
			}
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
			Button("Paste") { pasteAnything() }
				.disabled(EntityClipboard.read().isEmpty
					&& AddFlows.pasteboardFileURLs().isEmpty)
		}
	}

	// MARK: - Rows

	private var vmRootRow: some View {
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
		.font(.system(size: theme.metrics.rowFontSize))
		.frame(height: theme.metrics.treeRowHeight)
		.tag(SidebarNode.vmRoot)
		.contextMenu {
			Button("Rename") { renamingRoot = true }
			// A copied entity (disk/kernel/mount from any VM) pastes first; plain file
			// URLs keep the Finder routing.
			Button("Paste") { pasteAnything() }
				.disabled(EntityClipboard.read().isEmpty
					&& AddFlows.pasteboardFileURLs().isEmpty)
			Divider()
			Button("Delete VM…", role: .destructive) { viewModel.deleteVM(vm) }
		}
	}

	// In-place rename: Return commits (Esc cancels), so no extra confirmation dialog.
	private func commitRename(to newName: String) {
		viewModel.requestRename(vm, to: newName, profiles: profiles)
	}

	@ViewBuilder
	private var diskGroup: some View {
		let disks = vm.disks
		group(.group("Disks"), symbol: MachmanSymbols.diskName, title: "Disks",
			count: disks.count, menu: {
				Button("Add Existing Disk…") {
					AddFlows.chooseExistingDisk(viewModel: viewModel, vm: vm.name)
				}
				Button("Paste") { pasteIntoDisks() }
					.disabled(!canPasteIntoDisks)
			}) {
			ForEach(disks.filter { matches($0.name, $0.path) }) { disk in
				HStack(spacing: 6) {
					Image(systemName: Self.symbol(for: disk.type))
						.font(.system(size: theme.metrics.iconSize))
						.foregroundStyle(disk.owned == false ? Color.secondary : Color.primary)
					if renamingNode == .disk(disk.id) {
						RenameField(initial: disk.name ?? "") { newName in
							renamingNode = nil
							viewModel.renameDisk(vm.name, diskID: disk.id, newName: newName)
						} cancel: {
							renamingNode = nil
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
				.opacity(disk.isEnabled ? 1 : MachmanColors.inactiveEntryOpacity)
				.font(.system(size: theme.metrics.rowFontSize))
				.frame(height: theme.metrics.treeRowHeight)
				.tag(SidebarNode.disk(disk.id))
				.contextMenu { diskMenu(disk) }
			}
			if let preview = dragPreview, preview.section == .disks {
				TreeDropPreviewRow(preview: preview, icon: MachmanSymbols.diskStorage)
			}
		}
		.onDrop(of: [.fileURL], delegate: GroupDropDelegate(
			section: .disks, preview: $dragPreview,
			touched: { dragGeneration &+= 1 }, perform: performDiskDrop))
	}

	// Batch actions lead a row's menu when it sits inside a multi-selection.
	@ViewBuilder
	private func batchMenuItems(for node: SidebarNode) -> some View {
		if viewModel.treeSelection.count > 1, viewModel.treeSelection.contains(node) {
			let copyable = viewModel.copyableSelectionItems
			if !copyable.isEmpty {
				Button("Copy \(copyable.count) Items") {
					EntityClipboard.write(copyable)
				}
			}
			Button("Enable \(viewModel.treeSelection.count) Items") {
				viewModel.setSelectionEnabled(true, vm: vm)
			}
			Button("Disable \(viewModel.treeSelection.count) Items") {
				viewModel.setSelectionEnabled(false, vm: vm)
			}
			Divider()
		}
	}

	@ViewBuilder
	private func diskMenu(_ disk: DiskInfo) -> some View {
		batchMenuItems(for: .disk(disk.id))
		if let path = disk.path {
			Button("Copy") {
				EntityClipboard.write(EntityClipboard(kind: .disk, path: path))
			}
			Button("Show in Finder") { Self.revealInFinder(path) }
			Divider()
		}
		Button(disk.isEnabled ? "Disable" : "Enable") {
			viewModel.setEnabled(vm.name, disks: [disk.id: !disk.isEnabled])
		}
		if disk.type == .storage && disk.owned != false && !vm.state.isRunning {
			Button("Rename") { renamingNode = .disk(disk.id) }
		}
		if disk.owned == false {
			Button("Promote to Owned…") { viewModel.promoteDisk(vm.name, diskID: disk.id) }
		}
		Divider()
		Button(disk.owned == true ? "Delete…" : "Remove…", role: .destructive) {
			viewModel.requestRemoveDisk(vm.name, disk: disk)
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
				Button("Paste") { pasteIntoMounts() }
					.disabled(!canPasteIntoMounts)
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
				.opacity(mount.isEnabled ? 1 : MachmanColors.inactiveEntryOpacity)
				.font(.system(size: theme.metrics.rowFontSize))
				.frame(height: theme.metrics.treeRowHeight)
				.tag(SidebarNode.mount(mount.id))
				.contextMenu {
					batchMenuItems(for: .mount(mount.id))
					Button("Copy") {
						EntityClipboard.write(EntityClipboard(
							kind: .mount, path: mount.path, tag: mount.tag))
					}
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
			if let preview = dragPreview, preview.section == .mounts {
				TreeDropPreviewRow(preview: preview, icon: MachmanSymbols.mount)
			}
		}
		.onDrop(of: [.fileURL], delegate: GroupDropDelegate(
			section: .mounts, preview: $dragPreview,
			touched: { dragGeneration &+= 1 }, perform: performMountDrop))
	}

	@ViewBuilder
	private var serialGroup: some View {
		let ports = (vm.consolePorts ?? []) + (vm.uartPorts ?? [])
		// Selectable (the SSH-group pattern): the group inspector lists every interface
		// with the login state the guest-setup script reported.
		group(.group("Serial"), symbol: MachmanSymbols.serialUart, title: "Serial",
			count: ports.count, selectable: true) {
			// Search matches the display name AND the raw guest device (hvc0 finds
			// "Console 0" on an EFI VM).
			ForEach(ports.filter {
				matches($0.displayName(mode: vm.boot.mode)) || matches($0.guestDevice)
					|| matches($0.guestName)
			}) { port in
				serialRow(port)
			}
		}
	}

	// Ephemeral SSH sessions, once the guest has reported a user: the section title IS
	// the command, the + opens a fresh session tab, and the open sessions are the
	// children — no devices behind them, nothing persists.
	// Present as soon as SSH is part of this VM — the installer attached, or state on
	// file — because this section is where SSH is set up, not just where sessions live.
	private var sshSectionVisible: Bool {
		vm.ssh?.configured == true
	}

	@ViewBuilder
	private var sshGroup: some View {
		if sshSectionVisible {
			// Canvas tabs AND torn-off windows: a detached session is still open, and
			// dropping it from this list would leave no way back to its window.
			let open = openSSHSessions
			group(.group("SSH"), symbol: MachmanSymbols.deviceSSHSetup,
				title: "SSH", count: open.count, selectable: true, menu: {
				// The + accessory's reliable twin — List group labels can swallow clicks.
				Button("New SSH Session") { openSSHSession() }
					.disabled(!sshSessionReady)
				if sshUnreachable || sshWaiting {
					Button("Check Connection") { viewModel.refreshSSH(vm.name) }
				}
			}, accessory: { sshSessionButton }) {
				ForEach(open.filter {
					matches(sessions.sshSessionName(vm: vm.name, ref: $0))
				}) { ref in
					sshSessionRow(ref)
				}
			}
		}
	}

	// Open sessions: the canvas's tabs plus any torn into their own window.
	private var openSSHSessions: [SSHSessionRef] {
		var refs = canvases.canvas(for: vm.name).allOpenTabs
			.compactMap { tab -> SSHSessionRef? in
				if case .ssh(let ref) = tab { return ref }
				return nil
			}
		for torn in tornTabs.open where torn.vm == vm.name {
			if case .ssh(let ref) = torn.tab, !refs.contains(ref) {
				refs.append(ref)
			}
		}
		return refs
	}

	private func isTorn(_ tab: VMPaneTab) -> Bool {
		tornTabs.open.contains(TornTab(vm: vm.name, tab: tab))
	}

	private func sshSessionRow(_ ref: SSHSessionRef) -> some View {
		let torn = isTorn(.ssh(ref))
		return HStack(spacing: 6) {
			Image(systemName: MachmanSymbols.tabTerminal)
				.font(.system(size: theme.metrics.iconSize))
			Text(sessions.sshSessionName(vm: vm.name, ref: ref))
				.lineLimit(1)
			Spacer()
			if torn {
				Image(systemName: MachmanSymbols.newWindow)
					.font(.system(size: 9))
					.foregroundStyle(.tertiary)
					.help("Open in its own window")
			}
			Circle().fill(MachmanColors.connected)
				.frame(width: 5, height: 5)
				.help("Session open")
		}
		.font(.system(size: theme.metrics.rowFontSize))
		.frame(height: theme.metrics.treeRowHeight)
		.tag(SidebarNode.sshSession(ref))
		.contextMenu {
			if !torn {
				Button {
					detach(.ssh(ref))
				} label: {
					Label("Move to New Window", systemImage: MachmanSymbols.newWindow)
				}
			}
			Button("Close Session") { closeSSHSession(ref) }
		}
	}

	private func closeSSHSession(_ ref: SSHSessionRef) {
		// closeTerminal's torn branch: a torn-off tab IS its window — close that, and its
		// teardown ends the ssh process and drops the registry entry. Killing the process
		// in place would leave a zombie tree row over a wrong-message window.
		if isTorn(.ssh(ref)) {
			dismissWindow(id: "torn-tab", value: TornTab(vm: vm.name, tab: .ssh(ref)))
			return
		}
		sessions.dropSSHController(vm: vm.name, ref: ref)
		mutateCanvas { $0.close(.ssh(ref)) }
		viewModel.tabClosed(.ssh(ref), vm: vm.name)
	}

	// Move a tab out of the canvas into its own window (or focus the window it already
	// has). The controller is deliberately NOT torn down — the window adopts it — and the
	// window is opened a turn later so the canvas mount is gone first (SerialTerminalHost
	// hands the terminal to the newest mount).
	private func detach(_ tab: VMPaneTab) {
		if isTorn(tab) {
			openWindow(id: "torn-tab", value: TornTab(vm: vm.name, tab: tab))
			return
		}
		mutateCanvas { $0.close(tab) }
		viewModel.tabClosed(tab, vm: vm.name)   // next row click focuses the window
		let payload = TornTab(vm: vm.name, tab: tab)
		DispatchQueue.main.async { openWindow(id: "torn-tab", value: payload) }
	}

	// Installer devices (share-served guest-setup payloads): their own section — they
	// configure the guest rather than being hardware. Add actions live in the group's
	// context menu, the Disks convention.
	@ViewBuilder
	private var installerGroup: some View {
		let installers = (vm.devices ?? []).filter(\.kind.isInstaller)
		let macGuest = vm.boot.mode == .macOS
		group(.group("Installers"), symbol: MachmanSymbols.installerGroup,
			title: "Installers", count: installers.count, menu: {
			if macGuest, !installers.contains(where: { $0.kind == .consoleLoginInstaller }) {
				Button("Add Console Login") {
					viewModel.addDevice(vm.name, kind: .consoleLoginInstaller)
				}
			}
			if !installers.contains(where: { $0.kind == .sshInstaller }) {
				Button("Add SSH Setup") {
					viewModel.addDevice(vm.name, kind: .sshInstaller)
				}
			}
		}) {
			ForEach(installers.filter { matches($0.kind.displayLabel) }) { device in
				deviceRow(device)
					.tag(SidebarNode.device(device.kind))
					.contextMenu { deviceMenu(device) }
			}
		}
	}

	// A session can only start once the guest's sshd actually answers — the daemon's
	// reachability, not just an address (which appears long before sshd is listening).
	private var sshSessionReady: Bool {
		vm.state.isRunning && vm.ssh?.reachability == .ready
			&& SSHCommand.arguments(for: vm) != nil
	}

	private var sshUnreachable: Bool {
		vm.state.isRunning && vm.ssh?.reachability == .unreachable
	}

	private var sshWaiting: Bool {
		vm.state.isRunning && vm.ssh?.reachability == .waiting
	}

	// One control, three states: waiting on the guest, retry after giving up, or open a
	// session. The tooltip carries the reason, so the row itself stays quiet.
	@ViewBuilder
	private var sshSessionButton: some View {
		if sshWaiting {
			// No scaleEffect + fixed frame here: constraining a hosted AppKit
			// ProgressView to a size it also computes for itself makes it complain
			// ("maximum length … doesn't satisfy min <= max") on every layout pass.
			ProgressView()
				.controlSize(.small)
				.help("Waiting for sshd in the guest to answer…")
		} else if sshUnreachable {
			IconButton(symbol: MachmanSymbols.regenerate,
				tooltip: vm.ssh?.reachabilityDetail.map { "SSH: \($0) — try again" }
					?? "SSH did not answer — try again",
				font: .caption, flat: true) { viewModel.refreshSSH(vm.name) }
		} else {
			IconButton(symbol: MachmanSymbols.add,
				tooltip: sshSessionReady
					? "New SSH session tab"
					: "Sessions need the VM running and answering on port 22",
				font: .caption, flat: true) { openSSHSession() }
				.disabled(!sshSessionReady)
		}
	}

	private func openSSHSession() {
		guard SSHCommand.arguments(for: vm) != nil else { return }
		// "Session N": next number above every open session's current name.
		let taken = canvases.canvas(for: vm.name).allOpenTabs.compactMap { tab -> Int? in
			guard case .ssh(let ref) = tab else { return nil }
			let name = sessions.sshSessionName(vm: vm.name, ref: ref)
			guard name.hasPrefix("Session ") else { return nil }
			return Int(name.dropFirst("Session ".count))
		}
		let ref = SSHSessionRef(title: "Session \((taken.max() ?? 0) + 1)")
		mutateCanvas { $0.open(.ssh(ref)) }
	}

	private func serialRow(_ port: SerialPortInfo) -> some View {
		let ref = SerialPortRef(port)
		// Open counts a torn-off window too: the terminal is live either way.
		let open = canvases.canvas(for: vm.name).allOpenTabs.contains(.terminal(ref))
			|| isTorn(.terminal(ref))
		let gated = port.unavailable != nil
		let enabled = port.enabled ?? true
		return HStack(spacing: 6) {
			Image(systemName: port.kind == .console
				? MachmanSymbols.serialConsole : MachmanSymbols.serialUart)
				.font(.system(size: theme.metrics.iconSize))
			Text(port.displayName(mode: vm.boot.mode))
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
		.font(.system(size: theme.metrics.rowFontSize))
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
		batchMenuItems(for: .serial(ref))
		if !gated && enabled {
			if open {
				Button("Close Terminal (disconnect)") { closeTerminal(ref) }
			} else {
				Button("Open Terminal (connect)") { openTerminal(ref) }
			}
			if !isTorn(.terminal(ref)) {
				Button {
					detach(.terminal(ref))
				} label: {
					Label("Move to New Window", systemImage: MachmanSymbols.newWindow)
				}
			}
			Button("Properties") {
				openTerminal(ref)
				viewModel.treeSelection = [.serial(ref)]   // the inspector follows selection
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

	// Guest devices from the engine's assembly. Every kind is selectable (kinds without
	// settings get the generic info inspector); disabled devices dim, and a host-gated one
	// (Rosetta not installed, nested unsupported) carries the warning + reason.
	@ViewBuilder
	private var deviceGroup: some View {
		// Installer kinds render under Installers instead.
		let devices = (vm.devices ?? []).filter { !$0.kind.isInstaller }
		group(.group("Devices"), symbol: MachmanSymbols.deviceGroup, title: "Devices",
			count: devices.count) {
			ForEach(devices.filter { matches($0.kind.displayLabel) }) { device in
				deviceRow(device)
					.tag(SidebarNode.device(device.kind))
					.contextMenu { deviceMenu(device) }
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
		.font(.system(size: theme.metrics.rowFontSize))
		.frame(height: theme.metrics.treeRowHeight)
	}

	@ViewBuilder
	private func deviceMenu(_ device: DeviceInfo) -> some View {
		batchMenuItems(for: .device(device.kind))
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
					if renamingNode == (role == .kernel
						? SidebarNode.kernel(file.id) : SidebarNode.initramfs(file.id)) {
						RenameField(initial: file.label) { tag in
							renamingNode = nil
							viewModel.renameKernelTag(vm.name, path: file.id, tag: tag)
						} cancel: {
							renamingNode = nil
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
							.foregroundStyle(MachmanColors.activeEntry)
							.help("Active")
					}
				}
				.opacity(file.active ? 1 : MachmanColors.inactiveEntryOpacity)
				.font(.system(size: theme.metrics.rowFontSize))
				.frame(height: theme.metrics.treeRowHeight)
				.tag(role == .kernel
					? SidebarNode.kernel(file.id) : SidebarNode.initramfs(file.id))
				.contextMenu { kernelEntryMenu(file, role: role) }
			}
			if let preview = dragPreview, preview.section == .kernel(role) {
				TreeDropPreviewRow(
					preview: preview,
					icon: role == .kernel
						? MachmanSymbols.kernelFile : MachmanSymbols.initramfs)
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
			.font(.system(size: theme.metrics.rowFontSize))
			.frame(height: theme.metrics.treeRowHeight)
			.contextMenu {
				Button("Add From Disk…") {
					AddFlows.chooseKernelFile(viewModel: viewModel, vm: vm.name, role: role)
				}
				Button("Paste") { pasteIntoKernels(role: role) }
					.disabled(!canPasteIntoKernels(role: role))
			}
		}
		// Kernel parent is selectable (it has an inspector); the initramfs parent is a dim
		// unselectable group like the others. Both park (extra dim) while kernel boot is off.
		let droppable = dg.onDrop(of: [.fileURL], delegate: GroupDropDelegate(
			section: .kernel(role), preview: $dragPreview,
			touched: { dragGeneration &+= 1 },
			perform: { performKernelDrop($0, role: role) }))
		if role == .kernel {
			droppable
				.tag(SidebarNode.group("Kernel"))
				.opacity(kernelSectionParked ? 0.45 : 1)
		} else {
			droppable.opacity(kernelSectionParked ? 0.45 : MachmanColors.dimmedRowOpacity)
		}
	}

	@ViewBuilder
	private func kernelEntryMenu(_ file: KernelEntry, role: KernelRole) -> some View {
		if file.active {
			Button("Deselect") { setActiveKernelPath(nil, role: role) }
		} else {
			Button("Select") { setActiveKernelPath(file.id, role: role) }
		}
		Button("Copy") {
			EntityClipboard.write(EntityClipboard(
				kind: role == .kernel ? .kernel : .initramfs, path: file.id))
		}
		Button("Show in Finder") { Self.revealInFinder(file.id) }
		if file.owned && !vm.state.isRunning {
			Button("Rename") {
				renamingNode = role == .kernel ? .kernel(file.id) : .initramfs(file.id)
			}
		}
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
				let fileName = (vm.boot.ownedKernels ?? [])
					.first(where: { $0.path == file.id })?.fileName
					?? (file.id as NSString).lastPathComponent
				viewModel.requestDeleteKernel(vm.name, path: file.id, fileName: fileName)
			}
		}
	}

	private func setActiveKernelPath(_ path: String?, role: KernelRole) {
		viewModel.setActiveKernelFile(vm, role: role, path: path)
	}

	// MARK: - Group scaffold

	// Group parents are dimmed and NOT selectable (no tag — selection skips them); their
	// add actions live in a row-level context menu on the label. `accessory` renders as a
	// trailing control before the count (the SSH group's +). `selectable` is for the
	// groups that ARE a thing in their own right and carry an inspector (Kernel, SSH):
	// they keep a tag and full opacity.
	@ViewBuilder
	private func group<Content: View, MenuItems: View, Accessory: View>(
		_ node: SidebarNode, symbol: String, title: String, count: Int,
		selectable: Bool = false,
		@ViewBuilder menu: @escaping () -> MenuItems = { EmptyView() },
		@ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
		@ViewBuilder content: @escaping () -> Content
	) -> some View {
		let disclosure = DisclosureGroup(isExpanded: groupBinding(node)) {
			content()
		} label: {
			HStack(spacing: 6) {
				Image(systemName: symbol)
					.font(.system(size: theme.metrics.iconSize))
					.foregroundStyle(.secondary)
				Text(title).fontWeight(.medium)
				Spacer()
				accessory()
				Text("\(count)")
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.monospacedDigit()
			}
			.font(.system(size: theme.metrics.rowFontSize))
			.frame(height: theme.metrics.treeRowHeight)
			.contextMenu { menu() }
		}
		if selectable {
			disclosure.tag(node)
		} else {
			disclosure.opacity(MachmanColors.dimmedRowOpacity)
		}
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
			// A torn-off tab keeps its single mount: focus its window instead.
			if TornTabRegistry.shared.isOpen(vm: vm.name, tab: .config) {
				openWindow(id: "torn-tab", value: TornTab(vm: vm.name, tab: .config))
				return
			}
			mutateCanvas { $0.open(.config) }
		case .serial(let ref):
			let ports = (vm.consolePorts ?? []) + (vm.uartPorts ?? [])
			guard let port = ports.first(where: { SerialPortRef($0) == ref }),
				port.unavailable == nil, port.enabled ?? true else { return }
			openTerminal(ref)
		case .sshSession(let ref):
			// Rows exist only for OPEN sessions — selecting one focuses wherever it
			// lives: its canvas tab, or the window it was torn into.
			if isTorn(.ssh(ref)) {
				openWindow(id: "torn-tab", value: TornTab(vm: vm.name, tab: .ssh(ref)))
				return
			}
			mutateCanvas { $0.activate(.ssh(ref)) }
		default:
			break
		}
	}

	// MARK: - Section drops (validated by the hovering preview; routed here on release)
	// Each receives only the items that fit its section (TreeDragPreview.adds).

	private func performDiskDrop(_ urls: [URL]) {
		for url in urls {
			AddFlows.askDiskReferenceOrCopy(viewModel: viewModel, vm: vm.name, url: url)
		}
	}

	private func performMountDrop(_ urls: [URL]) {
		for url in urls {
			viewModel.addMount(vm.name, path: url.path, tag: url.lastPathComponent)
		}
	}

	private func performKernelDrop(_ urls: [URL], role: KernelRole) {
		for url in urls {
			viewModel.promoteKernel(
				vm.name, role: role, sourcePath: url.path,
				tag: url.deletingPathExtension().lastPathComponent)
		}
	}

	// MARK: - Section paste (each group takes only what fits it)

	private static func isDirectory(_ url: URL) -> Bool {
		TreeDropValidator.isDirectory(url)
	}

	// Everything on the clipboard pastes into this VM: entities by their own kinds,
	// plain file URLs by the Finder routing.
	private func pasteAnything() {
		let entities = EntityClipboard.read()
		if !entities.isEmpty {
			for entity in entities {
				entity.paste(into: vm.name, viewModel: viewModel)
			}
			return
		}
		_ = AddFlows.handleFileURLs(
			AddFlows.pasteboardFileURLs(), viewModel: viewModel, vm: vm.name)
	}

	private var canPasteIntoDisks: Bool {
		let entities = EntityClipboard.read()
		if !entities.isEmpty { return entities.contains { $0.kind == .disk } }
		return AddFlows.pasteboardFileURLs().contains { !Self.isDirectory($0) }
	}

	private func pasteIntoDisks() {
		let matching = EntityClipboard.read().filter { $0.kind == .disk }
		if !matching.isEmpty {
			for entity in matching {
				entity.paste(into: vm.name, viewModel: viewModel)
			}
			return
		}
		for url in AddFlows.pasteboardFileURLs() where !Self.isDirectory(url) {
			AddFlows.askDiskReferenceOrCopy(viewModel: viewModel, vm: vm.name, url: url)
		}
	}

	private var canPasteIntoMounts: Bool {
		let entities = EntityClipboard.read()
		if !entities.isEmpty { return entities.contains { $0.kind == .mount } }
		return AddFlows.pasteboardFileURLs().contains { Self.isDirectory($0) }
	}

	private func pasteIntoMounts() {
		let matching = EntityClipboard.read().filter { $0.kind == .mount }
		if !matching.isEmpty {
			for entity in matching {
				entity.paste(into: vm.name, viewModel: viewModel)
			}
			return
		}
		for url in AddFlows.pasteboardFileURLs() where Self.isDirectory(url) {
			viewModel.addMount(vm.name, path: url.path, tag: url.lastPathComponent)
		}
	}

	private func canPasteIntoKernels(role: KernelRole) -> Bool {
		let entities = EntityClipboard.read()
		let kind: EntityClipboard.Kind = role == .kernel ? .kernel : .initramfs
		if !entities.isEmpty { return entities.contains { $0.kind == kind } }
		return AddFlows.pasteboardFileURLs().contains { !Self.isDirectory($0) }
	}

	private func pasteIntoKernels(role: KernelRole) {
		let kind: EntityClipboard.Kind = role == .kernel ? .kernel : .initramfs
		let matching = EntityClipboard.read().filter { $0.kind == kind }
		if !matching.isEmpty {
			for entity in matching {
				entity.paste(into: vm.name, viewModel: viewModel)
			}
			return
		}
		for url in AddFlows.pasteboardFileURLs() where !Self.isDirectory(url) {
			viewModel.promoteKernel(
				vm.name, role: role, sourcePath: url.path,
				tag: url.deletingPathExtension().lastPathComponent)
		}
	}

	private func mutateCanvas(_ change: (inout CanvasState) -> Void) {
		var c = canvases.canvas(for: vm.name)
		change(&c)
		canvases.setCanvas(c, for: vm.name)
	}

	private func openTerminal(_ ref: SerialPortRef) {
		// A torn-off tab keeps its single mount: focus its window instead.
		if TornTabRegistry.shared.isOpen(vm: vm.name, tab: .terminal(ref)) {
			openWindow(id: "torn-tab", value: TornTab(vm: vm.name, tab: .terminal(ref)))
			return
		}
		// Instant: just record the tab. The canvas builds + connects the terminal lazily.
		mutateCanvas { $0.open(.terminal(ref)) }
	}

	private func closeTerminal(_ ref: SerialPortRef) {
		// A torn-off tab IS its window — close that, and its teardown drops the
		// controller. Dropping the controller in place would strand the window on its
		// connecting spinner: ensureController only runs from onAppear, which an
		// in-place branch flip never re-fires.
		if isTorn(.terminal(ref)) {
			dismissWindow(id: "torn-tab", value: TornTab(vm: vm.name, tab: .terminal(ref)))
			return
		}
		sessions.dropController(vm: vm.name, ref: ref)
		mutateCanvas { $0.close(.terminal(ref)) }
		viewModel.tabClosed(.terminal(ref), vm: vm.name)
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

	private static func copyToPasteboard(_ value: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(value, forType: .string)
	}

	private static func revealInFinder(_ path: String) {
		NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
	}
}
