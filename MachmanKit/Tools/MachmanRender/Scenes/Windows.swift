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

	@MainActor
	static func mainWindow(_ ctx: SceneContext, inspector: Bool) -> AnyView {
		ctx.viewModel.showInfoPanel = inspector
		return AnyView(VMNavigationView(
			viewModel: ctx.viewModel, selection: .constant(ctx.vm.name),
			profiles: ctx.profiles, daemonVersion: "1.0.10"))
	}

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
			"window.main.no-inspector", "VMNavigationView, inspector closed",
			widths: RenderScene.windowWidths, height: 820, chrome: .window,
			panels: { ctx in [tree(ctx)] }
		) { ctx in
			mainWindow(ctx, inspector: false)
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
	]
}
