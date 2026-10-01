//
//  Windows.swift
//  MachmanRender
//
//  Whole windows and the sidebar: the main window at the standard window widths (with its
//  toolbar, drawn in a titled never-ordered window, the glass columns painted with their
//  real views), a torn-off tab's window, and the device tree on its own.
//

import SwiftUI
import MachmanAPI
import MachmanUI
import MachmanFixtures
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

enum WindowScenes {
	@MainActor
	static func tree(_ ctx: SceneContext) -> AnyView {
		AnyView(VMDeviceTreeView(
			viewModel: ctx.viewModel, sessions: ctx.terminals, canvases: ctx.canvases,
			profiles: ctx.profiles, vm: ctx.vm))
	}

	// The tree with a Finder drag hovering its Disks group (the files don't exist, so the
	// classifier reads the URLs' trailing slashes).
	@MainActor
	static func treeWithDiskDrop(_ ctx: SceneContext, _ urls: [URL]) -> AnyView {
		let preview = TreeDragPreview.resolve(
			section: .disks, urls: urls, isDirectory: { $0.hasDirectoryPath })
		return AnyView(VMDeviceTreeView(
			viewModel: ctx.viewModel, sessions: ctx.terminals, canvases: ctx.canvases,
			profiles: ctx.profiles, vm: ctx.vm, dragPreview: preview))
	}

	@MainActor
	static func mainWindow(_ ctx: SceneContext, inspector: Bool) -> AnyView {
		ctx.viewModel.showInfoPanel = inspector
		return AnyView(VMNavigationView(
			viewModel: ctx.viewModel, selection: .constant(ctx.vm.name),
			profiles: ctx.profiles, daemonVersion: "1.0.10"))
	}

	// Two SSH sessions with fixed identities: SSHSessionRef lives in MachmanUI, which the
	// fixtures can't import, so the scene file holds them.
	static let canvasSession = SSHSessionRef(
		id: UUID(uuidString: "5C3E1A7B-0D2F-4E61-9A8B-7C6D5E4F3A21")!, title: "Session 1")
	static let restoredSession = SSHSessionRef(
		id: UUID(uuidString: "8F1D2C3B-4A5E-4F60-8B7A-6C5D4E3F2A10")!, title: "Session 2")

	static let all: [RenderScene] = [
		RenderScene(
			"window.main", "VMNavigationView, inspector open",
			widths: RenderScene.windowWidths, height: 820, chrome: .window,
			panels: { ctx in
				[
					tree(ctx),
					// The inspector column runs under the titlebar; its content starts below.
					AnyView(InspectorView(
						viewModel: ctx.viewModel, sessions: ctx.terminals,
						profiles: ctx.profiles, vm: ctx.vm)
						.padding(.top, 52)),
				]
			}
		) { ctx in
			mainWindow(ctx, inspector: true)
		},
		RenderScene(
			"window.main.not-responding", "VMNavigationView, Debian's vmhost not responding",
			widths: RenderScene.windowWidths, height: 820, chrome: .window,
			vms: Samples.libraryWithStalledHost,
			panels: { ctx in
				[
					tree(ctx),
					AnyView(InspectorView(
						viewModel: ctx.viewModel, sessions: ctx.terminals,
						profiles: ctx.profiles, vm: ctx.vm)
						.padding(.top, 52)),
				]
			}
		) { ctx in
			mainWindow(ctx, inspector: true)
		},
		RenderScene(
			"window.main.no-inspector", "VMNavigationView, inspector closed",
			widths: RenderScene.windowWidths, height: 820, chrome: .window,
			panels: { ctx in [tree(ctx)] }
		) { ctx in
			mainWindow(ctx, inspector: false)
		},
		// T8: the active canvas tab selects its tree row, and the inspector follows it. The
		// sample console socket is under /var/empty, so the terminal's connect fails there.
		RenderScene(
			"window.main.console-tab",
			"VMNavigationView, Debian's Console 0 tab active; tree row and inspector follow",
			widths: RenderScene.windowWidths, height: 820, chrome: .window,
			panels: { ctx in
				[
					tree(ctx),
					AnyView(InspectorView(
						viewModel: ctx.viewModel, sessions: ctx.terminals,
						profiles: ctx.profiles, vm: ctx.vm)
						.padding(.top, 52)),
				]
			}
		) { ctx in
			var canvas = ctx.canvases.canvas(for: "Debian")
			canvas.open(.config)
			canvas.open(.terminal(InspectorScenes.console))
			ctx.canvases.setCanvas(canvas, for: "Debian")
			return mainWindow(ctx, inspector: true)
		},
		RenderScene(
			"window.torn", "TornTabWindowView, Debian's config tab torn off",
			widths: [800], height: 520, chrome: .window
		) { ctx in
			AnyView(TornTabWindowView(
				connection: ctx.connection, profiles: ctx.profiles,
				payload: TornTab(vm: "Debian", tab: .config)))
		},
		RenderScene("sidebar.tree", "VMDeviceTreeView", widths: [270], height: 760) { ctx in
			tree(ctx)
		},
		// Taller than the window's tree: the Kernel and Initramfs groups sit below the fold.
		RenderScene(
			"sidebar.tree.kernel", "VMDeviceTreeView, kernel-boot VM", widths: [270],
			height: 1000
		) { ctx in
			ctx.viewModel.select(name: "Kernel Lab")
			return tree(ctx)
		},
		// A live session in the canvas, and a torn session window the system restored after a
		// relaunch: no controller behind it, so it is not an open session (T20).
		RenderScene(
			"sidebar.tree.ssh-sessions",
			"VMDeviceTreeView, a canvas SSH session and a torn session restored after relaunch",
			widths: [270], height: 760
		) { ctx in
			var canvas = ctx.canvases.canvas(for: "Debian")
			canvas.open(.ssh(canvasSession))
			ctx.canvases.setCanvas(canvas, for: "Debian")
			ctx.terminals.renameSSHSession(vm: "Debian", ref: canvasSession, to: "Session 1")
			ctx.tornTabs.open.insert(TornTab(vm: "Debian", tab: .ssh(restoredSession)))
			return tree(ctx)
		},
		RenderScene(
			"sidebar.tree.drop-mixed", "VMDeviceTreeView, files and a folder dragged onto Disks",
			widths: [270], height: 760
		) { ctx in
			treeWithDiskDrop(ctx, Samples.mixedDrop())
		},
		RenderScene(
			"sidebar.tree.drop-refused", "VMDeviceTreeView, a folder dragged onto Disks",
			widths: [270], height: 760
		) { ctx in
			treeWithDiskDrop(ctx, Samples.mixedDrop().filter(\.hasDirectoryPath))
		},
	]
}
