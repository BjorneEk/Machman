//
//  Inspectors.swift
//  MachmanRender
//
//  The inspector column, drawn through InspectorView with the tree selection set — exactly
//  the dispatch the app uses — at the standard inspector widths.
//

import SwiftUI
import MachmanAPI
import MachmanUI
import MachmanFixtures
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

enum InspectorScenes {
	static let height: CGFloat = 820

	// `vms` are the VMs the stub serves; `select` is the one whose inspector is drawn.
	static func inspector(
		_ name: String, _ summary: String,
		vms: @escaping () -> [VMInfo] = Samples.library,
		select vm: String = "Debian", node: SidebarNode?
	) -> RenderScene {
		RenderScene(
			"inspector.\(name)", summary, widths: RenderScene.inspectorWidths,
			height: height, vms: vms
		) { ctx in
			ctx.viewModel.select(name: vm)
			ctx.viewModel.treeSelection = node.map { [$0] } ?? []
			return AnyView(InspectorView(
				viewModel: ctx.viewModel, sessions: ctx.terminals, profiles: ctx.profiles,
				vm: ctx.vm))
		}
	}

	static let all: [RenderScene] = [
		inspector("vm", "VMInspector (no tree selection)", node: nil),
		inspector("disk", "DiskInspector, owned storage disk", node: .disk("storage:system")),
		inspector(
			"disk-iso", "DiskInspector, referenced ISO",
			node: .disk("iso:file:///Users/demo/Downloads/debian-13-arm64-netinst.iso")),
		inspector(
			"mount", "MountInspector, virtiofs mount",
			node: .mount("7B0E4F52-3C1A-4D55-9E0B-2A6C1D9F0A11")),
		inspector(
			"serial", "SerialInspector, console port of a running VM",
			node: .serial(SerialPortRef(kind: .console, index: 0))),
		inspector("device.graphics", "GraphicsInspector", node: .device(.graphics)),
		inspector("device.network", "NetworkInspector", node: .device(.network)),
		inspector("guest-setup", "GuestSetupInspector", node: .device(.guestSetup)),
		inspector("ssh", "SSHInspector", node: .group("SSH")),
		inspector(
			"kernel", "KernelParentInspector", select: "Kernel Lab", node: .group("Kernel")),
		inspector(
			"kernel.entry", "KernelEntryInspector, active kernel with an override",
			select: "Kernel Lab",
			node: .kernel(Samples.kernelBoot().boot.ownedKernels![0].path)),
	]
}
