//
//  TreeSectionProbe.swift
//  MachmanDesktopUITests
//
//  One device-tree section (TreeStorageSection, TreeSSHSection, …) laid out on its own over
//  a TreeContext built as VMDeviceTreeView builds it, its groups open as the tree opens them
//  at launch, so a test reads the section's rows, badges and accessories (their help and
//  labels). TreeMenuProbe's twin for rows instead of menus; no List around them, so a row
//  reads as its own elements rather than a table row.
//

import SwiftUI
import MachmanAPI
import MachmanUI
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

struct TreeSectionProbe: View {
	// VMDeviceTreeView's groups open at launch.
	static let openGroups: Set<SidebarNode> = [
		.group("Disks"), .group("Mounts"), .group("Serial"), .group("SSH"),
		.group("Installers"), .group("Devices"), .group("Kernel"), .group("Initramfs"),
	]

	let harness: UIHarness
	let vm: VMInfo
	let content: @MainActor (TreeContext) -> AnyView

	@State private var renamingRoot = false
	@State private var renamingNode: SidebarNode?
	@State private var dragPreview: TreeDragPreview?
	@State private var expanded: Set<SidebarNode> = TreeSectionProbe.openGroups
	@Environment(\.openWindow) private var openWindow

	init(harness: UIHarness, vm: VMInfo, content: @escaping @MainActor (TreeContext) -> AnyView) {
		self.harness = harness
		self.vm = vm
		self.content = content
	}

	var body: some View {
		let context = TreeContext(
			viewModel: harness.viewModel, sessions: harness.terminals,
			canvases: harness.canvases, tornTabs: harness.tornTabs,
			pasteboard: harness.pasteboard, profiles: harness.profiles, vm: vm, filter: "",
			renamingRoot: $renamingRoot, renamingNode: $renamingNode, renameDraft: nil,
			dragPreview: $dragPreview, expanded: $expanded, dragTouched: {},
			openWindow: openWindow)
		VStack(alignment: .leading, spacing: 0) {
			content(context)
		}
		.frame(width: 260, alignment: .leading)
	}
}
