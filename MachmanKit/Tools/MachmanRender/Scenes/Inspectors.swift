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

	// `vms` are the VMs the stub serves; `select` is the one whose inspector is drawn;
	// `setup` adjusts the context first (session metadata, stub state) when a node needs it.
	static func inspector(
		_ name: String, _ summary: String,
		vms: @escaping () -> [VMInfo] = Samples.library,
		select vm: String = "Debian", node: SidebarNode?,
		setup: @escaping @MainActor (SceneContext) -> Void = { _ in }
	) -> RenderScene {
		inspector(
			name, summary, vms: vms, select: vm, nodes: node.map { [$0] } ?? [],
			setup: setup)
	}

	// A multi-selection: every node selected at once.
	static func inspector(
		_ name: String, _ summary: String,
		vms: @escaping () -> [VMInfo] = Samples.library,
		select vm: String = "Debian", nodes: Set<SidebarNode>,
		setup: @escaping @MainActor (SceneContext) -> Void = { _ in }
	) -> RenderScene {
		RenderScene(
			"inspector.\(name)", summary, widths: RenderScene.inspectorWidths,
			height: height, vms: vms
		) { ctx in
			ctx.viewModel.select(name: vm)
			setup(ctx)
			ctx.viewModel.treeSelection = nodes
			return AnyView(InspectorView(
				viewModel: ctx.viewModel, sessions: ctx.terminals, profiles: ctx.profiles,
				vm: ctx.vm))
		}
	}

	static func device(
		_ kind: DeviceKind, _ summary: String, select vm: String = "Debian"
	) -> RenderScene {
		inspector("device.\(kind.rawValue)", summary, select: vm, node: .device(kind))
	}

	static let console = SerialPortRef(kind: .console, index: 0)
	static let iso = "iso:file:///Users/demo/Downloads/debian-13-arm64-netinst.iso"
	static let kernelLab = Samples.kernelBoot()
	// An open ephemeral SSH tab's identity (its title is fixed when the tab opens).
	static let sshSession = SSHSessionRef(
		id: UUID(uuidString: "0B5E55A0-0000-4000-8000-000000000001")!,
		title: "demo@192.168.64.7")

	static let all: [RenderScene] = [
		RenderScene(
			"inspector.none", "NoSelectionInspector (no VM selected)",
			widths: RenderScene.inspectorWidths, height: height
		) { _ in
			AnyView(NoSelectionInspector())
		},
		inspector("vm", "VMInspector (no tree selection)", node: nil),
		inspector("vm.macos", "VMInspector, installed macOS guest", select: "Sequoia", node: nil),
		inspector(
			"vm.not-responding", "VMInspector, vmhost not responding",
			vms: Samples.libraryWithStalledHost, node: nil),
		inspector(
			"multi", "MultiSelectionInspector, two disks",
			nodes: [.disk("storage:system"), .disk(iso)]),
		inspector("disk", "DiskInspector, owned storage disk", node: .disk("storage:system")),
		inspector("disk-iso", "DiskInspector, referenced ISO", node: .disk(iso)),
		inspector(
			"mount", "MountInspector, virtiofs mount",
			node: .mount("7B0E4F52-3C1A-4D55-9E0B-2A6C1D9F0A11")),
		inspector("serial-group", "SerialGroupInspector", node: .group("Serial")),
		inspector(
			"serial", "SerialInspector, console port of a running VM", node: .serial(console)),
		inspector(
			"uart", "SerialInspector, uart port of a kernel-boot VM", select: "Kernel Lab",
			node: .serial(SerialPortRef(kind: .uart, index: 0))),
		inspector("ssh", "SSHInspector", node: .group("SSH")),
		inspector(
			"ssh-session", "SSHSessionInspector, an open session tab",
			node: .sshSession(sshSession)
		) { ctx in
			// Names the session (and stamps its start) without spawning ssh.
			ctx.terminals.renameSSHSession(vm: "Debian", ref: sshSession, to: "Session 1")
		},
		inspector("guest-setup", "GuestSetupInspector", node: .device(.guestSetup)),
		inspector(
			"kernel", "KernelParentInspector", select: "Kernel Lab", node: .group("Kernel")),
		inspector(
			"kernel.entry", "KernelEntryInspector, active kernel with an override",
			select: "Kernel Lab", node: .kernel(kernelLab.boot.ownedKernels![0].path)),
		inspector(
			"initramfs.entry", "InitramfsEntryInspector, the active initramfs",
			select: "Kernel Lab", node: .initramfs(kernelLab.boot.ownedKernels![2].path)),
		device(.keyboard, "DeviceInspector, USB keyboard"),
		device(.trackpad, "DeviceInspector, Mac trackpad", select: "Sequoia"),
		device(.pointer, "DeviceInspector, pointing device"),
		device(.graphics, "GraphicsInspector"),
		device(.audioInput, "DeviceInspector, audio input"),
		device(.audioOutput, "DeviceInspector, audio output"),
		device(.network, "NetworkInspector"),
		device(.clipboard, "ClipboardInspector"),
		device(.entropy, "DeviceInspector, entropy", select: "Kernel Lab"),
		device(.rosetta, "RosettaInspector", select: "Kernel Lab"),
		inspector(
			"device.graphics.2560x1600", "GraphicsInspector, 2560 × 1600 (a width it shares)",
			vms: { [Samples.linuxDisplay(width: 2560, height: 1600)] },
			node: .device(.graphics)),
		inspector(
			"device.graphics.newer-capture",
			"GraphicsInspector, a capture mode from a newer Machman",
			vms: { [Samples.linuxNewerCaptureMode()] }, node: .device(.graphics)),
	]
}
