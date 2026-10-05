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
//  This view is the shell: the filter field, the List with its selection, Return, the drops
//  and the VM root row. Each section is its own view (Tree…Section) over one TreeContext;
//  TreeGroup holds the group and row scaffold, TreeMenus the row menus.
//

import SwiftUI
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
			TreeStorageSection(ctx: ctx)
			TreeSerialSection(ctx: ctx)
			TreeSSHSection(ctx: ctx)
			TreeDevicesSection(ctx: ctx)
			TreeKernelSection(ctx: ctx)
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
		// ←/→ fold and unfold a selected group label, as an outline did (TreeGroup, T26).
		.onKeyPress(.leftArrow) { foldSelectedGroup(open: false) }
		.onKeyPress(.rightArrow) { foldSelectedGroup(open: true) }
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

	private func foldSelectedGroup(open: Bool) -> KeyPress.Result {
		guard localSelection.count == 1, let node = localSelection.first,
			case .group = node else { return .ignored }
		withAnimation(.easeOut(duration: 0.15)) {
			if open { expanded.insert(node) } else { expanded.remove(node) }
		}
		return .handled
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
		.padding(.leading, TreeIndent.root)
		.treeRow(.vmRoot, onClick: { ctx.clicked(.vmRoot) }) { ctx.rootMenu() }
	}

	// In-place rename: Return commits (Esc cancels), so no extra confirmation dialog.
	private func commitRename(to newName: String) {
		viewModel.requestRename(vm, to: newName, profiles: profiles)
	}
}
