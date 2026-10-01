//
//  VMListViewModel+Tabs.swift
//  MachmanDesktopCore
//
//  The one place tabs close and tear off (Q3). A tab is a canvas entry, maybe a live
//  terminal behind it, maybe a torn-off window holding it, and a tree row selected for it;
//  every close site — the tree, the canvas, the SSH session inspector, ⌘W, a torn window's
//  teardown, a removed port — ends here, so the controller and the row always go together.
//

import Foundation
import MachmanAPI
import MachmanUI

extension VMListViewModel {
	// Close a tab wherever it lives. A torn-off tab IS its window: the window is ordered to
	// close and its teardown (tornWindowClosed) ends the terminal. Ending it here instead
	// would strand the window — a serial one on its connecting spinner (ensureController runs
	// only from onAppear, which an in-place branch flip never re-fires), an ssh one as a
	// zombie row over a "session ended" window. dismissWindow is a view action; models post.
	public func closeTab(_ tab: VMPaneTab, vm: String) {
		let torn = TornTab(vm: vm, tab: tab)
		if tornTabs.open.contains(torn) {
			tornTabs.orders[torn] = .close
			return
		}
		var canvas = canvases.canvas(for: vm)
		canvas.close(tab)
		canvases.setCanvas(canvas, for: vm)
		Self.endTab(tab, vm: vm, terminals: terminals, viewModel: self)
	}

	// A torn window went away (closed by the user, by its order, or by the system). Static,
	// so a window that closes mid-reconnect — no view model — still ends its terminal.
	public static func tornWindowClosed(
		_ payload: TornTab, registry: TornTabRegistry, terminals: TerminalSessions,
		viewModel: VMListViewModel?
	) {
		registry.open.remove(payload)
		endTab(payload.tab, vm: payload.vm, terminals: terminals, viewModel: viewModel)
	}

	// A terminal lives exactly as long as the thing showing it, tab or window; its row goes
	// with it.
	private static func endTab(
		_ tab: VMPaneTab, vm: String, terminals: TerminalSessions, viewModel: VMListViewModel?
	) {
		terminals.drop(tab, vm: vm)
		viewModel?.tabClosed(tab, vm: vm)
	}

	// Show a tab: a torn-off one keeps its single mount, so its payload comes back for the
	// caller to focus that window (openWindow is a view action; torn windows dedupe by
	// value); anything else opens or focuses in the canvas and nil comes back. Session rows
	// exist only for open sessions, so an ssh tab is activated, never opened anew.
	public func revealTab(_ tab: VMPaneTab, vm: String) -> TornTab? {
		let torn = TornTab(vm: vm, tab: tab)
		if tornTabs.open.contains(torn) { return torn }
		var canvas = canvases.canvas(for: vm)
		switch tab {
		case .config, .terminal:
			canvas.open(tab)
		case .ssh:
			canvas.activate(tab)
		}
		canvases.setCanvas(canvas, for: vm)
		return nil
	}

	// True when a tab was closed (⌘W falls back to closing the window otherwise).
	@discardableResult
	public func closeActiveTab() -> Bool {
		guard let name = selectedName, let tab = canvases.canvas(for: name).activeTab else {
			return false
		}
		closeTab(tab, vm: name)
		return true
	}

	// Take a tab off the canvas for its own window. The controller stays: the window adopts
	// it. The caller opens the window a turn later, once this mount is gone.
	public func tearOff(_ tab: VMPaneTab, vm: String) -> TornTab {
		var canvas = canvases.canvas(for: vm)
		canvas.close(tab)
		canvases.setCanvas(canvas, for: vm)
		tabClosed(tab, vm: vm)   // the next row click focuses the window
		return TornTab(vm: vm, tab: tab)
	}

	// Opening rides on selection CHANGE (the tree's only channel), so a row left selected
	// after its tab closed is a dead end — clicking it again cannot re-fire. Every path
	// that takes a tab off a canvas (close, tear-off, torn-window close) reports here.
	public func tabClosed(_ tab: VMPaneTab, vm: String) {
		guard vm == selectedName else { return }
		treeSelection.remove(Self.treeNode(for: tab))
	}

	static func treeNode(for tab: VMPaneTab) -> SidebarNode {
		switch tab {
		case .config: return .vmRoot
		case .terminal(let ref): return .serial(ref)
		case .ssh(let ref): return .sshSession(ref)
		}
	}

	// The tree mirrors the canvas (T8): when the shown VM's active tab CHANGES — a tab
	// click, ⇧⌘[ / ], a pane click, a close's fallback, a drag between panes — its row is
	// selected, so the inspector follows the tab the user is working in. Divider drags,
	// reorders, other VMs' canvases and renames (the incoming layouts lack the old key)
	// leave the selection alone. Nothing reopens: the tree's deferred mirror skips openNode
	// when the published selection already matches the List's. Runs inside the store's
	// willSet, so canvases still holds the old layouts.
	func canvasesWillChange(_ incoming: [String: CanvasState]) {
		guard let name = selectedName else { return }
		let before = canvases.canvas(for: name).activeTab
		guard let after = incoming[name]?.activeTab, after != before else { return }
		let node = Self.treeNode(for: after)
		if treeSelection != [node] { treeSelection = [node] }
	}

	// MARK: - SSH sessions

	// The VM's open sessions: its canvas's ssh tabs in order, then the sessions torn into
	// their own windows. A torn window counts only while its controller lives — a window
	// the system restored after a relaunch holds none (sessions die with the app), so it
	// is a notice, not a session (T20).
	public func openSSHSessions(vm: String) -> [SSHSessionRef] {
		var refs = canvases.canvas(for: vm).allOpenTabs.compactMap { tab -> SSHSessionRef? in
			if case .ssh(let ref) = tab { return ref }
			return nil
		}
		let torn = tornTabs.open
			.compactMap { torn -> SSHSessionRef? in
				guard torn.vm == vm, case .ssh(let ref) = torn.tab,
					terminals.sshController(vm: vm, ref: ref) != nil else { return nil }
				return ref
			}
			.sorted { ($0.title, $0.id.uuidString) < ($1.title, $1.id.uuidString) }
		for ref in torn where !refs.contains(ref) {
			refs.append(ref)
		}
		return refs
	}

	// "Session N": the next number above every open session's current name, torn ones
	// included, so a new tab never repeats a name still showing in a window.
	public func nextSSHSessionTitle(vm: String) -> String {
		let prefix = "Session "
		let taken = openSSHSessions(vm: vm).compactMap { ref -> Int? in
			let name = terminals.sshSessionName(vm: vm, ref: ref)
			guard name.hasPrefix(prefix) else { return nil }
			return Int(name.dropFirst(prefix.count))
		}
		return prefix + String((taken.max() ?? 0) + 1)
	}

	// MARK: - Cycling

	// Whether Next/Previous Tab have anywhere to go: the active pane holds another tab.
	public var canCycleTabs: Bool {
		guard let name = selectedName else { return false }
		return (canvases.canvas(for: name).activePane?.tabs.count ?? 0) > 1
	}

	public func cycleTab(forward: Bool) {
		guard let name = selectedName else { return }
		var canvas = canvases.canvas(for: name)
		guard let pane = canvas.activePane, pane.tabs.count > 1,
			let current = pane.active,
			let index = pane.tabs.firstIndex(of: current) else { return }
		let count = pane.tabs.count
		canvas.activate(pane.tabs[(index + (forward ? 1 : count - 1)) % count])
		canvases.setCanvas(canvas, for: name)
	}
}
