//
//  MenuProbe.swift
//  MachmanDesktopUITests
//
//  A context menu's content reaches the accessibility tree only once the menu opens, which a
//  test never does. TreeMenuProbe lays a device-tree menu's content (TreeMenus.swift) out as
//  views instead, over a TreeContext built exactly as VMDeviceTreeView builds it, so every
//  Button SwiftUI would put in the NSMenu reads as an AXButton with its title, enabled state
//  and help — what the menu item shows. Limits: a nested Menu reads as one element (its
//  items stay out of reach), a Divider is no element, and CanvasTabItem's menu is private.
//

import SwiftUI
import MachmanAPI
import MachmanUI
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

struct TreeMenuProbe: View {
	let harness: UIHarness
	let vm: VMInfo
	let content: @MainActor (TreeContext) -> AnyView

	@State private var renamingRoot = false
	@State private var renamingNode: SidebarNode?
	@State private var dragPreview: TreeDragPreview?
	@State private var expanded: Set<SidebarNode> = []
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
			pasteboard: harness.pasteboard, vm: vm, filter: "",
			renamingRoot: $renamingRoot, renamingNode: $renamingNode, renameDraft: nil,
			dragPreview: $dragPreview, expanded: $expanded, dragTouched: {},
			openWindow: openWindow)
		VStack(alignment: .leading) {
			content(context)
		}
	}
}
