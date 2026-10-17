//
//  TreeContext.swift
//  MachmanDesktopUI
//
//  What the device tree's sections share (VMDeviceTreeView): the stores they read, the VM
//  they list, the filter, and the state the shell owns that they write — the rename target,
//  the drag preview, the groups' expansion. Sections hold no @State of their own. Also here:
//  the filter rules and the actions rows share (open, detach, drop, paste); the rows' menus
//  are in TreeMenus.
//

import SwiftUI
import AppKit
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

// A DynamicProperty: whatever holds a context observes the same five stores the shell does,
// so it redraws on the same changes even when SwiftUI finds its other inputs unchanged.
@MainActor
struct TreeContext: DynamicProperty {
	@ObservedObject var viewModel: VMListViewModel
	@ObservedObject var sessions: TerminalSessions
	@ObservedObject var canvases: CanvasStateStore
	@ObservedObject var tornTabs: TornTabRegistry
	@ObservedObject var pasteboard: PasteboardWatch
	let profiles: TerminalProfileStore
	let vm: VMInfo
	let filter: String
	@Binding var renamingRoot: Bool
	// Entry being renamed in place (owned storage disks + owned kernel files).
	@Binding var renamingNode: SidebarNode?
	// A render scene's draft for the rename it starts with.
	let renameDraft: String?
	// A drag hovering a section: drives the would-be preview row + copy/forbidden cursor.
	@Binding var dragPreview: TreeDragPreview?
	@Binding var expanded: Set<SidebarNode>
	// Called on every drop-delegate touch: the shell's preview-expiry watchdog.
	let dragTouched: () -> Void
	let openWindow: OpenWindowAction
}

// MARK: - Filter

extension TreeContext {
	// Rows filter on what they show; group counts keep the real totals.
	func matches(_ candidates: String?...) -> Bool {
		filter.isEmpty || candidates.contains {
			$0?.localizedCaseInsensitiveContains(filter) == true
		}
	}

	// A filter naming a section ("disks") shows that section whole.
	func titleMatches(_ section: TreeSection) -> Bool {
		!filter.isEmpty && section.title.localizedCaseInsensitiveContains(filter)
	}

	// The rows a section lists: all of them unfiltered or on a title match, else the matches.
	func sectionRows<Row>(
		_ section: TreeSection, _ all: [Row], matching: (Row) -> Bool
	) -> [Row] {
		filter.isEmpty || titleMatches(section) ? all : all.filter(matching)
	}

	// N1: a section with rows shows; an empty one only unfiltered (or on a title match),
	// and only when the tree is where its things are added (TreeSection.staysWhenEmpty).
	func shows(_ section: TreeSection, rows: Int) -> Bool {
		TreeSection.isVisible(
			section, rows: rows, filtering: !filter.isEmpty && !titleMatches(section))
	}
}

// MARK: - Groups

extension TreeContext {
	func groupBinding(_ node: SidebarNode) -> Binding<Bool> {
		Binding(
			get: { expanded.contains(node) },
			set: { if $0 { expanded.insert(node) } else { expanded.remove(node) } })
	}

	// The section's Finder drop target (TreeDrop).
	func dropDelegate(_ section: TreeDragPreview.Section) -> GroupDropDelegate {
		GroupDropDelegate(
			section: section, preview: $dragPreview,
			touched: dragTouched, perform: { drop($0, on: section) })
	}

	// Whether a drag hovers the section (its preview row is something to fold, N2).
	func previews(_ section: TreeDragPreview.Section) -> Bool {
		dragPreview?.section == section
	}

	// The would-be entry while a drag hovers the section.
	@ViewBuilder
	func dropPreview(in section: TreeDragPreview.Section, icon: String) -> some View {
		if let preview = dragPreview, preview.section == section {
			TreeDropPreviewRow(preview: preview, icon: icon)
		}
	}
}

// MARK: - Behaviour

extension TreeContext {
	func isTorn(_ tab: VMPaneTab) -> Bool {
		tornTabs.open.contains(TornTab(vm: vm.name, tab: tab))
	}

	// Open a row (VMListViewModel.openTreeRow: VM root → configuration, a usable port → its
	// terminal, a session → its tab); a torn-off tab's window is focused instead.
	func open(_ node: SidebarNode) {
		if let torn = viewModel.openTreeRow(node, vm: vm) {
			openWindow(id: "torn-tab", value: torn)
		}
	}

	// A plain click selects the row and opens it, a row already selected included (arrow
	// keys leave rows selected without opening them); ⌘/⇧-clicks stay the List's, a
	// control-click is a menu click, and a click into a rename field is not an open. A
	// rename elsewhere in the tree doesn't block it: that rename ends as focus leaves it.
	func clicked(_ node: SidebarNode) {
		guard NSEvent.modifierFlags.isDisjoint(with: [.command, .shift, .control]),
			!isRenaming(node) else { return }
		if let torn = viewModel.treeRowClicked(node, vm: vm) {
			openWindow(id: "torn-tab", value: torn)
		}
	}

	func isRenaming(_ node: SidebarNode) -> Bool {
		(node == .vmRoot && renamingRoot) || renamingNode == node
	}

	// The rename in place runs the inspector fields' checks and entry points (H37): a draft
	// with a problem stays in the field with its reason, an unchanged one sends nothing.
	func renameProblem(_ node: SidebarNode, _ draft: String) -> String? {
		viewModel.treeRenameProblem(node, draft: draft, on: vm)
	}

	func commitRename(_ node: SidebarNode, to draft: String) {
		endRename(node)
		viewModel.submitTreeRename(node, draft: draft, on: vm)
	}

	// Ends `node`'s rename only: a field losing focus to another row's rename leaves that one.
	func endRename(_ node: SidebarNode) {
		if node == .vmRoot {
			renamingRoot = false
		} else if renamingNode == node {
			renamingNode = nil
		}
	}

	// Move a tab out of the canvas into its own window (or focus the window it already
	// has). The controller is deliberately NOT torn down — the window adopts it
	// (tearOffAndOpen).
	func detach(_ tab: VMPaneTab) {
		viewModel.tearOffAndOpen(tab, vm: vm.name) { openWindow(id: "torn-tab", value: $0) }
	}

	func mutateCanvas(_ change: (inout CanvasState) -> Void) {
		var c = canvases.canvas(for: vm.name)
		change(&c)
		canvases.setCanvas(c, for: vm.name)
	}

	// Instant: just record the tab. The canvas builds + connects the terminal lazily.
	func openTerminal(_ ref: SerialPortRef) {
		reveal(.terminal(ref))
	}

	// A torn-off tab keeps its single mount: focus its window instead of the canvas.
	func reveal(_ tab: VMPaneTab) {
		if let torn = viewModel.revealTab(tab, vm: vm.name) {
			openWindow(id: "torn-tab", value: torn)
		}
	}
}

// MARK: - Section drops and paste (AddFlows+Sections)
// A drop receives only the items that fit its section (TreeDragPreview.adds); paste
// takes the section's own copied kind, else the pasteboard's files that fit it.

extension TreeContext {
	func drop(_ urls: [URL], on section: TreeDragPreview.Section) {
		AddFlows.add(urls, to: section, vm: vm.name, viewModel: viewModel)
	}

	func paste(into section: TreeDragPreview.Section) {
		AddFlows.paste(
			into: section, entities: EntityClipboard.read(),
			fileURLs: AddFlows.pasteboardFileURLs(), vm: vm.name, viewModel: viewModel)
	}

	// Everything on the clipboard pastes into this VM: entities by their own kinds,
	// plain file URLs by the Finder routing.
	func pasteAnything() {
		AddFlows.paste(
			entities: EntityClipboard.read(), fileURLs: AddFlows.pasteboardFileURLs(),
			into: vm.name, viewModel: viewModel)
	}
}
