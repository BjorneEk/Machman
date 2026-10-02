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

	// A filter naming a section ("disks") shows that section whole.
	private func titleMatches(_ section: TreeSection) -> Bool {
		!filter.isEmpty && section.title.localizedCaseInsensitiveContains(filter)
	}

	// The rows a section lists: all of them unfiltered or on a title match, else the matches.
	private func sectionRows<Row>(
		_ section: TreeSection, _ all: [Row], matching: (Row) -> Bool
	) -> [Row] {
		filter.isEmpty || titleMatches(section) ? all : all.filter(matching)
	}

	// N1: a section with rows shows; an empty one only unfiltered (or on a title match),
	// and only when the tree is where its things are added (TreeSection.staysWhenEmpty).
	private func shows(_ section: TreeSection, rows: Int) -> Bool {
		TreeSection.isVisible(
			section, rows: rows, filtering: !filter.isEmpty && !titleMatches(section))
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
			if vm.showsKernelSections {
				kernelGroup(role: .kernel)
				kernelGroup(role: .initramfs)
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
			open(node)
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
			Button("Paste") { pasteAnything() }
				.disabled(!pasteboard.snapshot.canPasteAnything)
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
		.contentShape(Rectangle())
		.simultaneousGesture(TapGesture().onEnded { clicked(.vmRoot) })
		.tag(SidebarNode.vmRoot)
		.contextMenu {
			// Stop-first actions show dimmed with the reason while the VM runs (P14).
			Button("Rename") { renamingRoot = true }
				.stopFirst(vm, .renameVM)
			// A copied entity (disk/kernel/mount from any VM) pastes first; plain file
			// URLs keep the Finder routing.
			Button("Paste") { pasteAnything() }
				.disabled(!pasteboard.snapshot.canPasteAnything)
			Divider()
			Button("Delete VM…", role: .destructive) { viewModel.deleteVM(vm) }
				.stopFirst(vm, .deleteVM)
		}
	}

	// In-place rename: Return commits (Esc cancels), so no extra confirmation dialog.
	private func commitRename(to newName: String) {
		viewModel.requestRename(vm, to: newName, profiles: profiles)
	}

	@ViewBuilder
	private var diskGroup: some View {
		let disks = sectionRows(.disks, vm.disks) { matches($0.name, $0.path) }
		if shows(.disks, rows: disks.count) {
			group(.group("Disks"), symbol: MachmanSymbols.diskName, title: "Disks",
				count: vm.disks.count, menu: {
					Button("Add Existing Disk…") {
						AddFlows.chooseExistingDisk(viewModel: viewModel, vm: vm.name)
					}
					Button("Paste") { pasteIntoDisks() }
						.disabled(!pasteboard.snapshot.canPaste(into: .disks))
				}) {
				ForEach(disks) { disk in
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
		if disk.type == .storage && disk.owned != false {
			Button("Rename") { renamingNode = .disk(disk.id) }
				.stopFirst(vm, .renameDisk)
		}
		if disk.owned == false {
			Button("Promote to Owned") { viewModel.promoteDisk(vm.name, diskID: disk.id) }
				.stopFirst(vm, .promoteDisk)
		}
		Divider()
		// An owned disk's Delete… asks first; a reference detaches at once (H2: an ellipsis
		// promises a question).
		Button(disk.owned == true ? "Delete…" : "Remove", role: .destructive) {
			viewModel.requestRemoveDisk(vm.name, disk: disk)
		}
		.stopFirst(vm, .removeDisk)
	}

	@ViewBuilder
	private var mountGroup: some View {
		let mounts = sectionRows(.mounts, vm.mounts) { matches($0.path, $0.tag) }
		if shows(.mounts, rows: mounts.count) {
			group(.group("Mounts"), symbol: MachmanSymbols.mount, title: "Mounts",
				count: vm.mounts.count, menu: {
					Button("Add Mount Folder…") {
						AddFlows.chooseMountFolder(viewModel: viewModel, vm: vm.name)
					}
					Button("Paste") { pasteIntoMounts() }
						.disabled(!pasteboard.snapshot.canPaste(into: .mounts))
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
						Button("Remove", role: .destructive) {
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
	}

	@ViewBuilder
	private var serialGroup: some View {
		// Search matches the display name AND the raw guest device (hvc0 finds
		// "Console 0" on an EFI VM).
		let ports = sectionRows(.serial, vm.allSerialPorts) {
			matches($0.displayName(mode: vm.boot.mode)) || matches($0.guestDevice)
				|| matches($0.guestName)
		}
		// Selectable (the SSH-group pattern): the group inspector lists every interface
		// with the login state the guest-setup script reported.
		if shows(.serial, rows: ports.count) {
			group(.group("Serial"), symbol: MachmanSymbols.serialUart, title: "Serial",
				count: vm.allSerialPorts.count, selectable: true) {
				ForEach(ports) { port in
					serialRow(port)
				}
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
			// Canvas tabs AND live torn-off windows: a detached session is still open, and
			// dropping it from this list would leave no way back to its window.
			let open = viewModel.openSSHSessions(vm: vm.name)
			let rows = sectionRows(.ssh, open) {
				matches(sessions.sshSessionName(vm: vm.name, ref: $0))
			}
			if shows(.ssh, rows: rows.count) {
				group(.group("SSH"), symbol: MachmanSymbols.deviceSSHSetup,
					title: "SSH", count: open.count, selectable: true, menu: {
					// The + accessory's reliable twin — List group labels can swallow clicks.
					Button("New SSH Session") { openSSHSession() }
						.disabled(!sshSessionReady)
					if sshUnreachable || sshWaiting {
						Button("Check Connection") { viewModel.refreshSSH(vm.name) }
					}
				}, accessory: { sshSessionButton }) {
					ForEach(rows) { ref in
						sshSessionRow(ref)
					}
				}
			}
		}
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
			// theme.accentColor: List rows reset Color.accentColor to the system's (H20).
			Circle().fill(theme.accentColor)
				.frame(width: 5, height: 5)
				.help("Session open")
		}
		.font(.system(size: theme.metrics.rowFontSize))
		.frame(height: theme.metrics.treeRowHeight)
		.contentShape(Rectangle())
		.simultaneousGesture(TapGesture().onEnded { clicked(.sshSession(ref)) })
		.tag(SidebarNode.sshSession(ref))
		.contextMenu {
			if !torn {
				Button {
					detach(.ssh(ref))
				} label: {
					Label("Move to New Window", systemImage: MachmanSymbols.newWindow)
				}
			}
			// Canvas tab or torn window alike: closeTab knows which.
			Button("Close Session") { viewModel.closeTab(.ssh(ref), vm: vm.name) }
		}
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
		let payload = viewModel.tearOff(tab, vm: vm.name)
		DispatchQueue.main.async { openWindow(id: "torn-tab", value: payload) }
	}

	// Installer devices (share-served guest-setup payloads): their own section — they
	// configure the guest rather than being hardware. Add actions live in the group's
	// context menu, the Disks convention.
	@ViewBuilder
	private var installerGroup: some View {
		let installers = (vm.devices ?? []).filter(\.kind.isInstaller)
		let rows = sectionRows(.installers, installers) { matches($0.kind.displayLabel) }
		// The unified Guest Setup (the legacy Console Login / SSH Setup kinds migrate to it).
		if shows(.installers, rows: rows.count) {
			group(.group("Installers"), symbol: MachmanSymbols.installerGroup,
				title: "Installers", count: installers.count, menu: {
				if vm.canAddGuestSetup {
					Button("Add Guest Setup") {
						viewModel.addDevice(vm.name, kind: .guestSetup)
					}
				}
			}) {
				ForEach(rows) { device in
					deviceRow(device)
						.tag(SidebarNode.device(device.kind))
						.contextMenu { deviceMenu(device) }
				}
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
		let ref = SSHSessionRef(title: viewModel.nextSSHSessionTitle(vm: vm.name))
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
				Circle().fill(theme.accentColor)
					.frame(width: 5, height: 5)
					.help("Terminal open")
			}
		}
		.opacity(!enabled ? MachmanColors.inactiveEntryOpacity
			: (gated ? MachmanColors.dimmedRowOpacity : 1))
		.font(.system(size: theme.metrics.rowFontSize))
		.frame(height: theme.metrics.treeRowHeight)
		.contentShape(Rectangle())
		.simultaneousGesture(TapGesture().onEnded { clicked(.serial(ref)) })
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
				Button("Close Terminal (disconnect)") {
					viewModel.closeTab(.terminal(ref), vm: vm.name)
				}
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
			Button("Remove", role: .destructive) {
				if port.kind == .console {
					viewModel.removeConsolePort(vm.name)
				} else {
					viewModel.removeUartPort(vm.name)
				}
			}
			.stopFirst(vm, .changeSerialPorts)
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
		let rows = sectionRows(.devices, devices) { matches($0.kind.displayLabel) }
		if shows(.devices, rows: rows.count) {
			group(.group("Devices"), symbol: MachmanSymbols.deviceGroup, title: "Devices",
				count: devices.count) {
				ForEach(rows) { device in
					deviceRow(device)
						.tag(SidebarNode.device(device.kind))
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

	// The sections show once kernel boot is (or was) configured (VMInfo.showsKernelSections:
	// parked, dimmed, while kernel boot is off); their rows are VMInfo.kernelTreeEntries.

	// The VM cannot start kernel boot without a kernel path.
	private var missingKernelWarning: Bool {
		vm.boot.mode == .linuxKernel && (vm.boot.kernel?.kernelPath ?? "").isEmpty
	}

	@ViewBuilder
	private func kernelGroup(role: KernelRole) -> some View {
		let section: TreeSection = role == .kernel ? .kernel : .initramfs
		let entries = sectionRows(section, vm.kernelTreeEntries(role: role)) {
			matches($0.label)
		}
		if shows(section, rows: entries.count) {
			kernelDisclosure(role: role, title: section.title, entries: entries)
		}
	}

	@ViewBuilder
	private func kernelDisclosure(
		role: KernelRole, title: String, entries: [KernelTreeEntry]
	) -> some View {
		let dg = DisclosureGroup(isExpanded: groupBinding(.group(title))) {
			ForEach(entries) { file in
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
							.foregroundStyle(theme.accentColor)
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
					.disabled(!pasteboard.snapshot.canPaste(into: .kernel(role)))
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
				.opacity(vm.kernelSectionParked ? 0.45 : 1)
		} else {
			droppable.opacity(vm.kernelSectionParked ? 0.45 : MachmanColors.dimmedRowOpacity)
		}
	}

	@ViewBuilder
	private func kernelEntryMenu(_ file: KernelTreeEntry, role: KernelRole) -> some View {
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
		if file.owned {
			Button("Rename") {
				renamingNode = role == .kernel ? .kernel(file.id) : .initramfs(file.id)
			}
			.stopFirst(vm, .renameKernelFile)
		}
		if !file.owned {
			Button("Promote to Owned") {
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

	// Open a row (VMListViewModel.openTreeRow: VM root → configuration, a usable port → its
	// terminal, a session → its tab); a torn-off tab's window is focused instead.
	private func open(_ node: SidebarNode) {
		if let torn = viewModel.openTreeRow(node, vm: vm) {
			openWindow(id: "torn-tab", value: torn)
		}
	}

	// A plain click opens, a row already selected included (arrow keys leave rows selected
	// without opening them); ⌘/⇧-clicks only select, a control-click is a menu click, and
	// a click into a rename field is not an open. Simultaneous with the List's own click,
	// which keeps selecting as before.
	private func clicked(_ node: SidebarNode) {
		guard NSEvent.modifierFlags.isDisjoint(with: [.command, .shift, .control]),
			!renamingRoot, renamingNode == nil else { return }
		open(node)
	}

	// MARK: - Section drops (validated by the hovering preview; routed here on release)
	// Each receives only the items that fit its section (TreeDragPreview.adds).

	private func performDiskDrop(_ urls: [URL]) {
		AddFlows.askDiskReferenceOrCopy(viewModel: viewModel, vm: vm.name, urls: urls)
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

	// Everything on the clipboard pastes into this VM: entities by their own kinds,
	// plain file URLs by the Finder routing.
	private func pasteAnything() {
		AddFlows.paste(
			entities: EntityClipboard.read(), fileURLs: AddFlows.pasteboardFileURLs(),
			into: vm.name, viewModel: viewModel)
	}

	// The pasteboard's file URLs that fit a section (the drop rules).
	private func pastedFiles(fitting section: TreeDragPreview.Section) -> [URL] {
		TreeDropValidator.fitting(section: section, urls: AddFlows.pasteboardFileURLs())
	}

	private func pasteIntoDisks() {
		let matching = EntityClipboard.read().filter { $0.kind == .disk }
		if !matching.isEmpty {
			EntityClipboard.paste(matching, into: vm.name, viewModel: viewModel)
			return
		}
		let files = pastedFiles(fitting: .disks)
		if !files.isEmpty {
			AddFlows.askDiskReferenceOrCopy(viewModel: viewModel, vm: vm.name, urls: files)
		}
	}

	private func pasteIntoMounts() {
		let matching = EntityClipboard.read().filter { $0.kind == .mount }
		if !matching.isEmpty {
			EntityClipboard.paste(matching, into: vm.name, viewModel: viewModel)
			return
		}
		for url in pastedFiles(fitting: .mounts) {
			viewModel.addMount(vm.name, path: url.path, tag: url.lastPathComponent)
		}
	}

	private func pasteIntoKernels(role: KernelRole) {
		let kind: EntityClipboard.Kind = role == .kernel ? .kernel : .initramfs
		let matching = EntityClipboard.read().filter { $0.kind == kind }
		if !matching.isEmpty {
			EntityClipboard.paste(matching, into: vm.name, viewModel: viewModel)
			return
		}
		for url in pastedFiles(fitting: .kernel(role)) {
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

	// Instant: just record the tab. The canvas builds + connects the terminal lazily.
	private func openTerminal(_ ref: SerialPortRef) {
		reveal(.terminal(ref))
	}

	// A torn-off tab keeps its single mount: focus its window instead of the canvas.
	private func reveal(_ tab: VMPaneTab) {
		if let torn = viewModel.revealTab(tab, vm: vm.name) {
			openWindow(id: "torn-tab", value: torn)
		}
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
		PasteboardWatch.general.refresh()
	}

	private static func revealInFinder(_ path: String) {
		NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
	}
}
