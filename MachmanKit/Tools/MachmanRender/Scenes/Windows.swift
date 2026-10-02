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

	// The tree with text in its filter field.
	@MainActor
	static func filteredTree(_ ctx: SceneContext, _ filter: String) -> AnyView {
		AnyView(VMDeviceTreeView(
			viewModel: ctx.viewModel, sessions: ctx.terminals, canvases: ctx.canvases,
			profiles: ctx.profiles, vm: ctx.vm, filter: filter))
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

	// The main window's disconnected state, as the connect loop leaves it, centred in a
	// window of the scene's size as the app's window centres it. The details are the errors'
	// own texts (RPCConnection.ConnectionError, expire, APIVersionMismatch).
	@MainActor
	private static func connecting(
		_ status: ConnectionStatus, approval: Bool = false
	) -> AnyView {
		AnyView(ConnectionStatusView(
			status: status, loginItemNeedsApproval: approval,
			retry: {}, launchDaemon: {}, openLoginItems: {})
			.frame(maxWidth: .infinity, maxHeight: .infinity))
	}

	// One serial tab's content as a canvas pane or torn window shows it (T10).
	@MainActor
	private static func serialTab(_ ctx: SceneContext, _ ref: SerialPortRef) -> AnyView {
		AnyView(TerminalTabContent(
			sessions: ctx.terminals, profiles: ctx.profiles, vm: ctx.vm, ref: ref,
			stillWanted: { false }))
	}

	static let uart = SerialPortRef(kind: .uart, index: 0)

	// Kernel Lab's canvas split into three panes (configuration, Console 0, UART 0) with the
	// first divider dragged right, as far as the minimum pane width lets it go (L2).
	@MainActor
	static func threePanes(_ ctx: SceneContext) {
		ctx.viewModel.select(name: "Kernel Lab")
		var canvas = ctx.canvases.canvas(for: "Kernel Lab")
		canvas.open(.config)
		canvas.open(.terminal(InspectorScenes.console))
		canvas.open(.terminal(uart))
		canvas.split(.terminal(InspectorScenes.console))
		canvas.split(.terminal(uart))
		canvas.setFraction(0.7, at: 0)
		ctx.canvases.setCanvas(canvas, for: "Kernel Lab")
	}

	// The tree and the inspector, painted over the main window's glass columns.
	@MainActor
	static func treeAndInspector(_ ctx: SceneContext) -> [AnyView] {
		[
			tree(ctx),
			AnyView(InspectorView(
				viewModel: ctx.viewModel, sessions: ctx.terminals,
				profiles: ctx.profiles, vm: ctx.vm)
				.padding(.top, 52)),
		]
	}

	private static let refusedDetail = "cannot reach MachmanAgent at /var/folders/7k/"
		+ "0q8n1x52l3gr5mhkzz1y7rr0000gn/T/com.gustaffranzen.Machman/machman.sock: "
		+ "Connection refused"

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
			"window.main.mac-unfinished-copy",
			"VMNavigationView, the copy of a Mac whose install never finished",
			widths: RenderScene.windowWidths, height: 820, chrome: .window,
			vms: { [Samples.macOSUnfinishedCopy()] },
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
			"window.main.mac-install-failed",
			"VMNavigationView, a Mac whose install failed with a long reason",
			widths: RenderScene.windowWidths, height: 820, chrome: .window,
			vms: { [Samples.macOSFailedInstall()] },
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
		RenderScene(
			"window.main.activity", "VMNavigationView, two unseen problems in the activity list",
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
			PopoverScenes.seedActivity(ctx)
			// The corner as it looks once those cards and the toast have gone (the panels
			// are painted over it, so it would only show cut).
			for op in ctx.operations.operations { ctx.operations.dismiss(id: op.id) }
			ctx.viewModel.dismissToast(key: VMListViewModel.logToastKey(
				"Debian: " + Samples.screenRecordingWarning))
			return mainWindow(ctx, inspector: true)
		},
		// L1: the window at its fitting size is the floor its regions derive (a smaller
		// --widths proposal comes out at this size too).
		RenderScene(
			"window.main.floor", "VMNavigationView at its minimum size, inspector open",
			chrome: .window,
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
			"window.main.no-inspector.floor",
			"VMNavigationView at its minimum size, inspector closed",
			chrome: .window,
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
		// L2: three panes with the first divider at its limit stay inside the canvas.
		RenderScene(
			"window.main.three-panes",
			"VMNavigationView, Kernel Lab's canvas in three panes, first divider dragged right",
			widths: RenderScene.windowWidths, height: 820, chrome: .window,
			panels: treeAndInspector
		) { ctx in
			threePanes(ctx)
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
		// T13: the title follows a rename made after the window tore off. No controller, so
		// the adopt-only window shows its notice and never spawns ssh.
		RenderScene(
			"window.torn.ssh-renamed", "TornTabWindowView, an SSH session renamed to Build",
			widths: [800], height: 520, chrome: .window
		) { ctx in
			ctx.terminals.renameSSHSession(vm: "Debian", ref: canvasSession, to: "Build")
			return AnyView(TornTabWindowView(
				connection: ctx.connection, profiles: ctx.profiles,
				payload: TornTab(vm: "Debian", tab: .ssh(canvasSession))))
		},
		// T10: a serial tab without a socket says why, not always "Start the VM".
		RenderScene(
			"canvas.serial-tab.disabled", "TerminalTabContent, Console 0 disabled on a running VM",
			widths: [320, 640], height: 360, vms: { [Samples.disabledConsole()] }
		) { ctx in
			serialTab(ctx, InspectorScenes.console)
		},
		RenderScene(
			"canvas.serial-tab.gated", "TerminalTabContent, a UART this Mac can't attach",
			widths: [320, 640], height: 360, vms: { [Samples.gatedUART()] }
		) { ctx in
			serialTab(ctx, uart)
		},
		RenderScene(
			"canvas.serial-tab.restart", "TerminalTabContent, Console 0 enabled after the start",
			widths: [320, 640], height: 360, vms: { [Samples.consoleEnabledAfterStart()] }
		) { ctx in
			serialTab(ctx, InspectorScenes.console)
		},
		RenderScene(
			"canvas.serial-tab.waiting", "TerminalTabContent, a UART of a starting VM",
			widths: [320, 640], height: 360, vms: { [Samples.kernelBoot(state: .starting)] }
		) { ctx in
			serialTab(ctx, uart)
		},
		RenderScene(
			"window.connecting", "ConnectionStatusView, connecting", widths: [480, 900],
			height: 420
		) { _ in
			connecting(.connecting)
		},
		RenderScene(
			"window.connecting.unreachable", "ConnectionStatusView, the agent isn't there",
			widths: [480, 900], height: 420
		) { _ in
			connecting(.unavailable(ConnectionProblem(kind: .unreachable, detail: refusedDetail)))
		},
		RenderScene(
			"window.connecting.unreachable.approval",
			"ConnectionStatusView, the agent isn't there and its login item needs approval",
			widths: [480, 900], height: 420
		) { _ in
			connecting(
				.unavailable(ConnectionProblem(kind: .unreachable, detail: refusedDetail)),
				approval: true)
		},
		RenderScene(
			"window.connecting.not-answering", "ConnectionStatusView, a hung agent",
			widths: [480, 900], height: 420
		) { _ in
			connecting(.unavailable(ConnectionProblem(
				kind: .notAnswering,
				detail: "no reply to machman.hello after 10s — the serving process may be hung")))
		},
		RenderScene(
			"window.connecting.incompatible", "ConnectionStatusView, an agent of another api",
			widths: [480, 900], height: 420
		) { _ in
			connecting(.unavailable(ConnectionProblem(
				kind: .incompatible, detail: "daemon speaks api v2, client needs v1")))
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
		// N1: a filter hides the sections without a match; a section-title match shows it
		// whole; without a filter, empty sections hide unless the tree is their add path.
		RenderScene(
			"sidebar.tree.filter-none", "VMDeviceTreeView, a filter nothing matches",
			widths: [270], height: 760
		) { ctx in
			filteredTree(ctx, "nvme")
		},
		RenderScene(
			"sidebar.tree.filter-hvc", "VMDeviceTreeView, filtered to hvc",
			widths: [270], height: 760
		) { ctx in
			filteredTree(ctx, "hvc")
		},
		RenderScene(
			"sidebar.tree.filter-title", "VMDeviceTreeView, a filter matching the Disks title",
			widths: [270], height: 760
		) { ctx in
			filteredTree(ctx, "disks")
		},
		RenderScene(
			"sidebar.tree.bare", "VMDeviceTreeView, a VM without mounts, ports or Guest Setup",
			widths: [270], height: 760, vms: { [Samples.bareLinux()] }
		) { ctx in
			tree(ctx)
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
