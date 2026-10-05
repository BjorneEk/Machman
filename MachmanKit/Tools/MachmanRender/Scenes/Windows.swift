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
import MachmanClient
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

	// The tree with `hovered` drawn under a pointer (hover itself doesn't render).
	@MainActor
	static func hoveredTree(_ ctx: SceneContext, _ hovered: Set<SidebarNode>) -> AnyView {
		AnyView(VMDeviceTreeView(
			viewModel: ctx.viewModel, sessions: ctx.terminals, canvases: ctx.canvases,
			profiles: ctx.profiles, vm: ctx.vm, hovered: hovered))
	}

	// The tree with a Finder drag hovering one of its groups (the files don't exist, so the
	// classifier reads the URLs' trailing slashes).
	@MainActor
	static func treeWithDrop(
		_ ctx: SceneContext, on section: TreeDragPreview.Section = .disks, _ urls: [URL]
	) -> AnyView {
		let preview = TreeDragPreview.resolve(
			section: section, urls: urls, isDirectory: { $0.hasDirectoryPath })
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

	// One pane strip of Debian's tabs in `style`: the configuration selected, Console 0
	// drawn hovered (hover itself doesn't render), a session at rest (C6).
	@MainActor
	static func tabStrip(_ ctx: SceneContext, _ style: MachmanTabStyle) -> some View {
		let tabs: [(title: String, symbol: String, terminal: Bool)] = [
			(ctx.vm.name, MachmanSymbols.tabConfig, false),
			(ctx.vm.consolePorts?.first?.displayName(mode: ctx.vm.boot.mode) ?? "",
				MachmanSymbols.serialConsole, true),
			(canvasSession.title, MachmanSymbols.deviceSSHSetup, true),
		]
		return HStack(spacing: style == .capsule ? 6 : 0) {
			ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
				CanvasTabItem(
					title: tab.title, symbol: tab.symbol, isTerminal: tab.terminal,
					selected: index == 0, dragging: false, detachedDrag: false,
					dragOffset: .zero, canSplit: true, hasSiblings: true, closeAsks: false,
					tabStyle: style,
					metrics: MachmanMetrics(), onSelect: {}, onClose: {}, onCloseOthers: {},
					onSplit: {}, onTearOff: {}, onDragChanged: { _ in }, onDragEnded: {},
					reportFrame: { _ in }, hoverPreview: index == 1)
			}
		}
		.padding(.horizontal, style == .capsule ? 8 : 0)
		.padding(.vertical, style == .capsule ? 4 : 0)
		.background {
			if style == .rectangular { Rectangle().fill(.thinMaterial) }
		}
	}

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

	// Kernel Lab's console open in the second of two panes, its strip active (H20).
	@MainActor
	static func kernelLabConsoleSplit(_ ctx: SceneContext) {
		ctx.viewModel.select(name: "Kernel Lab")
		var canvas = ctx.canvases.canvas(for: "Kernel Lab")
		canvas.open(.config)
		canvas.open(.terminal(InspectorScenes.console))
		canvas.split(.terminal(InspectorScenes.console))
		ctx.canvases.setCanvas(canvas, for: "Kernel Lab")
	}

	static let orange = MachmanTheme(accent: .orange)

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

	// The connect screen's problems as ConnectionProblem.classify words real errors (W4).
	private static let refused = ConnectionProblem.classify(
		RPCConnection.ConnectionError.connectFailed("/var/empty/machman.sock", ECONNREFUSED))

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
		// P37: a VM whose vmhost Machman Agent hasn't reached yet is busy, not stopped — the
		// toolbar shows a spinner instead of Start.
		RenderScene(
			"window.main.unknown-state", "VMNavigationView, Debian's vmhost not reached yet",
			widths: RenderScene.windowWidths, height: 820, chrome: .window,
			vms: Samples.libraryWithUnreachedHost,
			panels: treeAndInspector
		) { ctx in
			mainWindow(ctx, inspector: true)
		},
		RenderScene(
			"window.main.never-answered", "VMNavigationView, Debian's vmhost never answered",
			widths: RenderScene.windowWidths, height: 820, chrome: .window,
			vms: Samples.libraryWithNeverAnsweredHost,
			panels: treeAndInspector
		) { ctx in
			mainWindow(ctx, inspector: true)
		},
		// P37 (review F1): the Network inspector's Regenerate MAC waits for the agent too.
		RenderScene(
			"window.main.unknown-state.network",
			"VMNavigationView, Debian's vmhost not reached yet, its Network device selected",
			widths: RenderScene.windowWidths, height: 820, chrome: .window,
			vms: Samples.libraryWithUnreachedHost,
			panels: treeAndInspector
		) { ctx in
			ctx.viewModel.treeSelection = [.device(.network)]
			return mainWindow(ctx, inspector: true)
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
			"window.main.mac-install-failed.readable",
			"VMNavigationView, a Mac whose install failed, with the reason it stores now",
			widths: RenderScene.windowWidths, height: 820, chrome: .window,
			vms: { [Samples.macOSFailedInstallReadable()] },
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
		// sample console socket is under /var/empty, so the terminal's connect fails there,
		// and the tab says so at once (T25).
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
			return AnyView(mainWindow(ctx, inspector: true)
				.environment(\.terminalDisconnectedGrace, .zero))
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
		// O-2: with the inspector closed, three panes raise the canvas floor to their own
		// minimums (3 × 120 pt plus two dividers), so none is squeezed below it.
		RenderScene(
			"window.main.three-panes.no-inspector.floor",
			"VMNavigationView at its minimum size, inspector closed, three canvas panes",
			chrome: .window,
			panels: { ctx in [tree(ctx)] }
		) { ctx in
			threePanes(ctx)
			return mainWindow(ctx, inspector: false)
		},
		// …and with it open the three share the content's 300 pt, under their minimum.
		RenderScene(
			"window.main.three-panes.floor",
			"VMNavigationView at its minimum size, inspector open, three canvas panes",
			chrome: .window,
			panels: treeAndInspector
		) { ctx in
			threePanes(ctx)
			return mainWindow(ctx, inspector: true)
		},
		// H20: the canvas's active-pane strip, the tree's dots and checks follow the accent.
		RenderScene(
			"window.main.accent", "VMNavigationView, Kernel Lab split in two, orange accent",
			widths: RenderScene.windowWidths, height: 820, chrome: .window,
			panels: { ctx in treeAndInspector(ctx).map { AnyView($0.machmanThemed(orange)) } }
		) { ctx in
			kernelLabConsoleSplit(ctx)
			return AnyView(mainWindow(ctx, inspector: true).machmanThemed(orange))
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
		// Q4: the canvas banner reads the same phase as the install's corner card.
		RenderScene(
			"canvas.preview.installing", "VMPreviewTabView, a macOS install downloading",
			widths: [320, 640], height: 420, vms: { [Samples.macOS("Sequoia")] }
		) { ctx in
			ctx.stub.emit(.installPhaseChanged(
				vm: "Sequoia", phase: Samples.downloadingMacInstall()))
			Offscreen.pump(until: { !ctx.operations.installPhases.isEmpty })
			return AnyView(VMPreviewTabView(vm: ctx.vm, viewModel: ctx.viewModel))
		},
		// W4: the display block's line under the spinner or start button, per state.
		RenderScene(
			"canvas.preview.stopping", "VMPreviewTabView while the guest shuts down",
			widths: [320, 640], height: 420, vms: { [Samples.stoppingLinux()] }
		) { ctx in
			AnyView(VMPreviewTabView(vm: ctx.vm, viewModel: ctx.viewModel))
		},
		RenderScene(
			"canvas.preview.error", "VMPreviewTabView, a VM that stopped with an error",
			widths: [320, 640], height: 420, vms: { [Samples.linux("Fedora", state: .error)] }
		) { ctx in
			AnyView(VMPreviewTabView(vm: ctx.vm, viewModel: ctx.viewModel))
		},
		RenderScene(
			"canvas.preview.unknown", "VMPreviewTabView, a VM whose state is unknown",
			widths: [320, 640], height: 420, vms: { [Samples.linux("Debian", state: .unknown)] }
		) { ctx in
			AnyView(VMPreviewTabView(vm: ctx.vm, viewModel: ctx.viewModel))
		},
		// C6: a tab that isn't selected rests unfilled and shows its hover plainly.
		RenderScene(
			"canvas.tabs.hover",
			"CanvasTabItem, selected, hovered and resting tabs in both tab styles"
		) { ctx in
			AnyView(VStack(alignment: .leading, spacing: 14) {
				tabStrip(ctx, .capsule)
				tabStrip(ctx, .rectangular)
			}
			.padding(14))
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
		// T25: a live port whose socket refused (the sample's is under /var/empty) says so.
		RenderScene(
			"canvas.serial-tab.disconnected",
			"TerminalTabContent, Console 0 of a running VM whose socket refused the connection",
			widths: [320, 640], height: 360
		) { ctx in
			let console = InspectorScenes.console
			ctx.terminals.ensureController(
				vm: ctx.vm.name, ref: console, socketPath: ctx.vm.consolePorts?[0].socketPath,
				profile: ctx.profiles.defaultProfile)
			Offscreen.pump(until: {
				ctx.terminals.controller(vm: ctx.vm.name, ref: console) != nil
			})
			return AnyView(serialTab(ctx, console).environment(\.terminalDisconnectedGrace, .zero))
		},
		// An ssh session that ended: the banner offers Reconnect while the guest answers on
		// port 22, Check Connection when it doesn't. A never-connected controller: no ssh.
		RenderScene(
			"canvas.ssh-tab.ended", "SSHSessionSurface, a session that ended, guest reachable",
			widths: [320, 640], height: 360
		) { ctx in
			AnyView(SSHSessionSurface(
				controller: SerialTerminalController(profile: ctx.profiles.defaultProfile),
				guestIsReachable: true, reconnect: {}, checkConnection: {}))
		},
		RenderScene(
			"canvas.ssh-tab.ended.unreachable",
			"SSHSessionSurface, a session that ended, guest not answering on port 22",
			widths: [320, 640], height: 360
		) { ctx in
			AnyView(SSHSessionSurface(
				controller: SerialTerminalController(profile: ctx.profiles.defaultProfile),
				guestIsReachable: false, reconnect: {}, checkConnection: {}))
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
			connecting(.unavailable(refused))
		},
		RenderScene(
			"window.connecting.unreachable.approval",
			"ConnectionStatusView, the agent isn't there and its login item needs approval",
			widths: [480, 900], height: 420
		) { _ in
			connecting(.unavailable(refused), approval: true)
		},
		RenderScene(
			"window.connecting.not-answering", "ConnectionStatusView, a hung agent",
			widths: [480, 900], height: 420
		) { _ in
			connecting(.unavailable(ConnectionProblem.classify(
				MachmanError(code: .timeout, message: "No answer within 10 seconds"))))
		},
		RenderScene(
			"window.connecting.incompatible", "ConnectionStatusView, an agent of another api",
			widths: [480, 900], height: 420
		) { _ in
			connecting(.unavailable(ConnectionProblem.classify(
				RemoteMachman.APIVersionMismatch(daemonAPI: 2, clientAPI: 3))))
		},
		RenderScene(
			"sidebar.agent-footer", "AgentFooter, the agent's version and the running count",
			widths: [220, 270]
		) { _ in
			AnyView(AgentFooter(version: "1.0.12", running: 2))
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
		// Every tagged row selected (Q11): each row kind's List tag draws as its highlight, so
		// a tree change that loses one shows in the pixels. Running, so no dot pulses.
		RenderScene(
			"sidebar.tree.select-all",
			"VMDeviceTreeView, Kernel Lab with every selectable row selected",
			widths: [270], height: 1000, vms: { [Samples.kernelBoot(state: .running)] }
		) { ctx in
			let vm = ctx.vm
			var canvas = ctx.canvases.canvas(for: vm.name)
			canvas.open(.ssh(canvasSession))
			ctx.canvases.setCanvas(canvas, for: vm.name)
			ctx.terminals.renameSSHSession(vm: vm.name, ref: canvasSession, to: "Session 1")
			var nodes: Set<SidebarNode> = [
				.vmRoot, .group("Serial"), .group("SSH"), .group("Kernel"),
				.sshSession(canvasSession),
			]
			nodes.formUnion(vm.disks.map { .disk($0.id) })
			nodes.formUnion(vm.mounts.map { .mount($0.id) })
			nodes.formUnion(vm.allSerialPorts.map { .serial(SerialPortRef($0)) })
			nodes.formUnion((vm.devices ?? []).map { .device($0.kind) })
			nodes.formUnion(vm.kernelTreeEntries(role: .kernel).map { .kernel($0.id) })
			nodes.formUnion(vm.kernelTreeEntries(role: .initramfs).map { .initramfs($0.id) })
			ctx.viewModel.treeSelection = nodes
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
		// N2: a section that stays empty is a leaf row — SSH with no session open, Kernel and
		// Initramfs before their first file — and gains its chevron with a row or a drag.
		RenderScene(
			"sidebar.tree.kernel-empty", "VMDeviceTreeView, kernel boot before any kernel file",
			widths: [270], height: 900, vms: { [Samples.kernelBootEmpty()] }
		) { ctx in
			tree(ctx)
		},
		// C4: every row that reacts to a click shows a hover: an entry (the system disk), an
		// unselectable label (Mounts) and a selectable one (Serial) next to the selected hvc0.
		RenderScene(
			"sidebar.tree.hover",
			"VMDeviceTreeView, the system disk, Mounts and Serial hovered beside the selected hvc0",
			widths: [270], height: 760
		) { ctx in
			ctx.viewModel.treeSelection = [.serial(InspectorScenes.console)]
			return hoveredTree(
				ctx, [.disk("storage:system"), .group("Mounts"), .group("Serial")])
		},
		// H37: the tree's rename runs the inspector field's checks; a draft with a problem
		// keeps the field open with the warning triangle (its help is the reason).
		RenderScene(
			"sidebar.tree.rename-problem",
			"VMDeviceTreeView, Alpine's system disk renamed to a name with a leading dot",
			widths: [270], height: 360, vms: { [Samples.linux("Alpine")] }
		) { ctx in
			AnyView(VMDeviceTreeView(
				viewModel: ctx.viewModel, sessions: ctx.terminals, canvases: ctx.canvases,
				profiles: ctx.profiles, vm: ctx.vm, renaming: .disk("storage:system"),
				renameDraft: ".system"))
		},
		RenderScene(
			"sidebar.tree.drop-kernel-empty",
			"VMDeviceTreeView, a kernel image dragged onto the empty Kernel section",
			widths: [270], height: 900, vms: { [Samples.kernelBootEmpty()] }
		) { ctx in
			treeWithDrop(ctx, on: .kernel(.kernel), Samples.kernelDrop())
		},
		// H20: Settings ▸ Accent ▸ Orange recolors Machman's own accent elements — inside the
		// tree's List rows too (live dots, the active kernel and initramfs checks).
		RenderScene(
			"sidebar.tree.accent", "VMDeviceTreeView, Kernel Lab with an orange accent",
			widths: [270], height: 1000
		) { ctx in
			kernelLabConsoleSplit(ctx)
			return AnyView(tree(ctx).machmanThemed(orange))
		},
		RenderScene(
			"sidebar.tree.drop-mixed", "VMDeviceTreeView, files and a folder dragged onto Disks",
			widths: [270], height: 760
		) { ctx in
			treeWithDrop(ctx, Samples.mixedDrop())
		},
		RenderScene(
			"sidebar.tree.drop-refused", "VMDeviceTreeView, a folder dragged onto Disks",
			widths: [270], height: 760
		) { ctx in
			treeWithDrop(ctx, Samples.mixedDrop().filter(\.hasDirectoryPath))
		},
	]
}
