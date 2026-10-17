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

	// Alpine's (stopped) system disk with `text` typed into Grow to.
	static func diskGrow(_ name: String, _ summary: String, text: String) -> RenderScene {
		RenderScene(name, summary, widths: RenderScene.inspectorWidths, height: height) { ctx in
			ctx.viewModel.select(name: "Alpine")
			return AnyView(
				DiskInspector(
					viewModel: ctx.viewModel, vm: ctx.vm, diskID: "storage:system",
					growText: text)
					.formStyle(.grouped))
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
			"machine.newer-boot", "VMInspector, a boot mode a newer Machman wrote",
			vms: { [Samples.newerBootMode()] }, select: "Alpine", node: nil),
		inspector(
			"vm.mac-install-unreached",
			"VMInspector, an unfinished Mac Machman Agent hasn't reached (Bootloader and "
				+ "Install wait)",
			vms: { [Samples.macOSUnfinishedUnreached()] }, select: "Sequoia", node: nil),
		inspector(
			"vm.not-responding", "VMInspector, vmhost not responding",
			vms: Samples.libraryWithStalledHost, node: nil),
		RenderScene(
			"inspector.vm.memory-clamped", "VMInspector, a memory entry lowered to the maximum",
			widths: RenderScene.inspectorWidths, height: height,
			vms: { [Samples.linuxMemoryAtMaximum()] }
		) { ctx in
			ctx.viewModel.select(name: "Alpine")
			return AnyView(
				VMInspector(
					viewModel: ctx.viewModel, profiles: ctx.profiles, vm: ctx.vm,
					memoryNote: "Lowered to this Mac’s maximum")
					.formStyle(.grouped))
		},
		// The same note as the view model words it (memory-clamped above passes a literal).
		RenderScene(
			"inspector.vm.memory-lowered", "VMInspector, the view model's lowered-memory note",
			widths: RenderScene.inspectorWidths, height: height,
			vms: { [Samples.linuxMemoryAtMaximum()] }
		) { ctx in
			ctx.viewModel.select(name: "Alpine")
			return AnyView(
				VMInspector(
					viewModel: ctx.viewModel, profiles: ctx.profiles, vm: ctx.vm,
					memoryNote: ctx.viewModel.memoryEntry("2048", floor: 0).note)
					.formStyle(.grouped))
		},
		RenderScene(
			"inspector.vm.name-taken", "VMInspector, a name another VM has",
			widths: RenderScene.inspectorWidths, height: height
		) { ctx in
			ctx.viewModel.select(name: "Alpine")
			return AnyView(
				VMInspector(
					viewModel: ctx.viewModel, profiles: ctx.profiles, vm: ctx.vm,
					nameDraft: "Sequoia")
					.formStyle(.grouped))
		},
		inspector(
			"multi", "MultiSelectionInspector, two disks",
			nodes: [.disk("storage:system"), .disk(iso)]),
		inspector(
			"vm.outdated-host", "VMInspector, run by an older vmhost",
			vms: Samples.libraryWithOutdatedHost, node: nil),
		// H52: Start at login on, so Safe mode dims with the daemon's reason.
		inspector(
			"vm.autostart", "VMInspector, Start at login on (Safe mode dims)",
			vms: { [Samples.linuxAutostart()] }, select: "Alpine", node: nil),
		inspector(
			"disk.outdated-host", "DiskInspector, run by an older vmhost",
			vms: Samples.libraryWithOutdatedHost, node: .disk("storage:system")),
		inspector(
			"multi.outdated-host", "MultiSelectionInspector, run by an older vmhost",
			vms: Samples.libraryWithOutdatedHost, nodes: [.disk("storage:system"), .disk(iso)]),
		// O-4: inside the lock, what changes no setting stays live — copy, reveal, guides,
		// Re-run Address Discovery and the port's terminal profile.
		inspector(
			"serial.outdated-host", "SerialInspector, run by an older vmhost",
			vms: Samples.libraryWithOutdatedHost, node: .serial(console)),
		inspector(
			"device.network.outdated-host", "Network DeviceInspector, run by an older vmhost",
			vms: Samples.libraryWithOutdatedHost, node: .device(.network)),
		inspector("disk", "DiskInspector, owned storage disk", node: .disk("storage:system")),
		inspector("disk-iso", "DiskInspector, referenced ISO", node: .disk(iso)),
		diskGrow("inspector.disk.grow", "DiskInspector, the Grow-to field", text: ""),
		diskGrow(
			"inspector.disk.grow-smaller", "DiskInspector, a grow size under the disk's own",
			text: "16"),
		diskGrow(
			"inspector.disk.grow-too-big", "DiskInspector, a grow past the free space",
			text: "500"),
		RenderScene(
			"inspector.disk.name-taken", "DiskInspector, a name the VM's other disk has",
			widths: RenderScene.inspectorWidths, height: height,
			vms: { [Samples.linuxTwoDisks()] }
		) { ctx in
			ctx.viewModel.select(name: "Alpine")
			return AnyView(
				DiskInspector(
					viewModel: ctx.viewModel, vm: ctx.vm, diskID: "storage:system",
					nameDraft: "data")
					.formStyle(.grouped))
		},
		RenderScene(
			"inspector.disk.name-refused", "DiskInspector, a rename the daemon refused",
			widths: RenderScene.inspectorWidths, height: height
		) { ctx in
			ctx.viewModel.select(name: "Alpine")
			return AnyView(
				DiskInspector(
					viewModel: ctx.viewModel, vm: ctx.vm, diskID: "storage:system",
					refusal: "kept uses system.raw from Alpine’s folder \u{2014} remove that "
						+ "disk from kept first")
					.formStyle(.grouped))
		},
		inspector(
			"disk.never-answered", "DiskInspector, a VM whose vmhost never answered",
			vms: { [Samples.neverAnswered()] }, select: "Alpine", node: .disk("storage:system")),
		inspector(
			"mount", "MountInspector, virtiofs mount",
			node: .mount("7B0E4F52-3C1A-4D55-9E0B-2A6C1D9F0A11")),
		RenderScene(
			"inspector.mount.tag-reserved", "MountInspector, a tag Machman reserves",
			widths: RenderScene.inspectorWidths, height: height
		) { ctx in
			ctx.viewModel.select(name: "Alpine")
			return AnyView(
				MountInspector(
					viewModel: ctx.viewModel, vm: ctx.vm,
					mountID: "7B0E4F52-3C1A-4D55-9E0B-2A6C1D9F0A11", tagDraft: "GuestSetup")
					.formStyle(.grouped))
		},
		inspector(
			"mount.manual", "MountInspector, a virtiofs mount the guest mounts by hand",
			vms: { [Samples.linuxManualMount()] }, select: "Alpine",
			node: .mount(Samples.srcMountID)),
		inspector(
			"mount.sshfs", "MountInspector, an sshfs mount",
			vms: { [Samples.linuxWithMounts()] }, node: .mount(Samples.notesMountID)),
		inspector(
			"mount.macos", "MountInspector, a macOS guest's mount",
			vms: { [Samples.macOSWithMount()] }, select: "Sequoia",
			node: .mount(Samples.srcMountID)),
		inspector(
			"vm.one-core", "VMInspector, a single-core VM",
			vms: { [Samples.linuxOneCore()] }, select: "Alpine", node: nil),
		inspector("serial-group", "SerialGroupInspector", node: .group("Serial")),
		inspector(
			"serial-group.kernel", "SerialGroupInspector, a console and a UART",
			select: "Kernel Lab", node: .group("Serial")),
		inspector(
			"serial-group.gated", "SerialGroupInspector, a UART this Mac gates",
			vms: { [Samples.kernelBootGatedUART()] }, select: "Kernel Lab",
			node: .group("Serial")),
		inspector(
			"serial-group.reported", "SerialGroupInspector, login states the guest reported",
			vms: { [Samples.linuxConsolesReported()] }, node: .group("Serial")),
		inspector(
			"serial", "SerialInspector, console port of a running VM", node: .serial(console)),
		inspector(
			"serial.logging", "SerialInspector, a running console logging to a file",
			vms: { [Samples.linuxConsoleLog()] }, node: .serial(console)),
		inspector(
			"serial.kernel-console",
			"SerialInspector, a kernel-boot console the guest hasn't reported",
			vms: { [Samples.kernelBootConsoleUnreported()] }, select: "Kernel Lab",
			node: .serial(console)),
		inspector(
			"uart", "SerialInspector, uart port of a kernel-boot VM", select: "Kernel Lab",
			node: .serial(SerialPortRef(kind: .uart, index: 0))),
		inspector(
			"uart.gated", "SerialInspector, a uart port on a host that gates uarts",
			vms: { [Samples.kernelBootGatedUART()] }, select: "Kernel Lab",
			node: .serial(SerialPortRef(kind: .uart, index: 0))),
		inspector(
			"uart.macos", "SerialInspector, a macOS guest's uart port",
			vms: { [Samples.macOSWithUART()] }, select: "Sequoia",
			node: .serial(SerialPortRef(kind: .uart, index: 0))),
		inspector("ssh", "SSHInspector", node: .group("SSH")),
		inspector(
			"ssh.spaced-name", "SSHInspector, a VM named with a space",
			vms: { [Samples.linuxSpacedName()] }, select: "Debian copy", node: .group("SSH")),
		inspector(
			"ssh.reverse-pending", "SSHInspector, a guest key awaiting approval",
			vms: { [Samples.linuxReverse(.pending)] }, node: .group("SSH")),
		inspector(
			"ssh.reverse-denied", "SSHInspector, a denied guest key",
			vms: { [Samples.linuxReverse(.denied)] }, node: .group("SSH")),
		inspector(
			"ssh.apostrophe-name", "SSHInspector, the ssh line of a VM named with an apostrophe",
			vms: { [Samples.linuxApostropheName()] }, select: "Bob's Ubuntu",
			node: .group("SSH")),
		RenderScene(
			"inspector.ssh.alias-invalid", "SSHInspector, an alias it can't use",
			widths: RenderScene.inspectorWidths, height: height
		) { ctx in
			ctx.viewModel.select(name: "Debian")
			return AnyView(
				SSHInspector(viewModel: ctx.viewModel, vm: ctx.vm, aliasDraft: "dev box")
					.formStyle(.grouped))
		},
		RenderScene(
			"inspector.ssh.alias-draft", "SSHInspector, an unsent valid alias",
			widths: RenderScene.inspectorWidths, height: height
		) { ctx in
			ctx.viewModel.select(name: "Debian")
			return AnyView(
				SSHInspector(
					viewModel: ctx.viewModel, vm: ctx.vm, aliasDraft: "debian-box.machman")
					.formStyle(.grouped))
		},
		inspector(
			"ssh-session", "SSHSessionInspector, an open session tab",
			node: .sshSession(sshSession)
		) { ctx in
			// Names the session (and stamps its start) without spawning ssh.
			ctx.terminals.renameSSHSession(vm: "Debian", ref: sshSession, to: "Session 1")
		},
		inspector(
			"ssh-session.outdated-host", "SSHSessionInspector, live under an older vmhost",
			vms: Samples.libraryWithOutdatedHost, node: .sshSession(sshSession)
		) { ctx in
			ctx.terminals.renameSSHSession(vm: "Debian", ref: sshSession, to: "Session 1")
		},
		inspector("guest-setup", "GuestSetupInspector", node: .device(.guestSetup)),
		inspector(
			"guest-setup.update-available", "GuestSetupInspector, report from script v3",
			vms: { [Samples.olderSetupScript("Debian")] }, node: .device(.guestSetup)),
		inspector(
			"guest-setup.notes", "GuestSetupInspector, a clean run with notes",
			vms: { [Samples.setupNotes("Debian")] }, node: .device(.guestSetup)),
		inspector(
			"guest-setup.failed-run", "GuestSetupInspector, a failed run keeps serving",
			vms: { [Samples.failedSetupRun("Debian")] }, node: .device(.guestSetup)),
		inspector(
			"guest-setup.kernel-reinstall",
			"GuestSetupInspector, a kernel-boot guest whose share automounts, reinstalling",
			vms: { [Samples.kernelBootReinstall()] }, select: "Kernel Lab",
			node: .device(.guestSetup)),
		inspector(
			"kernel", "KernelParentInspector", select: "Kernel Lab", node: .group("Kernel")),
		inspector(
			"kernel.entry", "KernelEntryInspector, active kernel with an override",
			select: "Kernel Lab", node: .kernel(kernelLab.boot.ownedKernels![0].path)),
		RenderScene(
			"inspector.kernel.entry.tag-invalid", "KernelEntryInspector, a tag it can't use",
			widths: RenderScene.inspectorWidths, height: height,
			vms: { [Samples.kernelBoot()] }
		) { ctx in
			ctx.viewModel.select(name: "Kernel Lab")
			return AnyView(
				KernelEntryInspector(
					viewModel: ctx.viewModel, vm: ctx.vm,
					path: kernelLab.boot.ownedKernels![0].path, tagDraft: "6.13/rc1")
					.formStyle(.grouped))
		},
		inspector(
			"initramfs.entry", "InitramfsEntryInspector, the active initramfs",
			select: "Kernel Lab", node: .initramfs(kernelLab.boot.ownedKernels![2].path)),
		RenderScene(
			"inspector.kernel.reselect", "KernelEntryInspector after moving from 6.12 to 6.6-lts",
			widths: RenderScene.inspectorWidths, height: height
		) { ctx in
			ctx.viewModel.select(name: "Kernel Lab")
			let kernels = kernelLab.boot.ownedKernels!
			ctx.viewModel.treeSelection = [.kernel(kernels[0].path)]
			// The second selection lands a main-queue turn later, as a click would.
			return AnyView(InspectorView(
				viewModel: ctx.viewModel, sessions: ctx.terminals, profiles: ctx.profiles,
				vm: ctx.vm
			).onAppear {
				DispatchQueue.main.async {
					ctx.viewModel.treeSelection = [.kernel(kernels[1].path)]
				}
			})
		},
		device(.keyboard, "DeviceInspector, USB keyboard"),
		device(.trackpad, "DeviceInspector, Mac trackpad", select: "Sequoia"),
		inspector(
			"device.trackpad.efi", "DeviceInspector, a Mac trackpad on a Linux guest",
			vms: { [Samples.linuxWithTrackpad()] }, node: .device(.trackpad)),
		device(.pointer, "DeviceInspector, pointing device"),
		device(.graphics, "GraphicsInspector"),
		device(.audioInput, "DeviceInspector, audio input"),
		device(.audioOutput, "DeviceInspector, audio output"),
		device(.network, "NetworkInspector"),
		// E56: an address no lease names, taken from the guest's report.
		inspector(
			"device.network.reported", "NetworkInspector, an address the guest reported",
			vms: { [Samples.reportedAddress()] }, node: .device(.network)),
		device(.clipboard, "ClipboardInspector"),
		device(.entropy, "DeviceInspector, entropy", select: "Kernel Lab"),
		device(.rosetta, "RosettaInspector", select: "Kernel Lab"),
		inspector(
			"device.graphics.2560x1600", "GraphicsInspector, 2560 × 1600 (a width it shares)",
			vms: { [Samples.linuxDisplay(width: 2560, height: 1600)] },
			node: .device(.graphics)),
		// H46: a macOS guest's Pixels per inch, the third bordered number field here.
		inspector(
			"device.graphics.macos", "GraphicsInspector, a macOS guest (Pixels per inch)",
			select: "Sequoia", node: .device(.graphics)),
		inspector(
			"device.graphics.newer-capture",
			"GraphicsInspector, a capture mode from a newer Machman",
			vms: { [Samples.linuxNewerCaptureMode()] }, node: .device(.graphics)),
		// RunDefaults narrow width: the Default start toggles at the inspector's 250 pt floor.
		RenderScene(
			"inspector.vm.default-start.floor",
			"VMInspector at the inspector's 250 pt floor, Start at login on",
			widths: [250], height: height, vms: { [Samples.linuxAutostart()] }
		) { ctx in
			ctx.viewModel.select(name: "Alpine")
			ctx.viewModel.treeSelection = []
			return AnyView(InspectorView(
				viewModel: ctx.viewModel, sessions: ctx.terminals, profiles: ctx.profiles,
				vm: ctx.vm))
		},
		// H58: a port's and a device's Enabled toggle off, and a console that isn't its
		// kind's last (no Remove).
		inspector(
			"serial.disabled", "SerialInspector, a console disabled before the start",
			vms: { [Samples.disabledConsole()] }, node: .serial(console)),
		inspector(
			"serial.first-of-four", "SerialInspector, the first of four consoles (no Remove)",
			vms: { [Samples.linuxConsolesReported()] }, node: .serial(console)),
		inspector(
			"device.graphics.disabled", "GraphicsInspector, a disabled display",
			vms: { [Samples.linuxNoDisplay(state: .stopped)] }, node: .device(.graphics)),
		// L7: the Bootloader's longest value, which drops under its label at the floor.
		inspector(
			"vm.kernel-boot", "VMInspector, a kernel-boot VM (Bootloader Kernel Boot)",
			select: "Kernel Lab", node: nil),
	]
}
