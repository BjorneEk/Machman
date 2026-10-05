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

	// True when a tab was closed or its close asks first (⌘W falls back to closing the
	// window otherwise).
	@discardableResult
	public func closeActiveTab() -> Bool {
		guard let name = selectedName, let tab = canvases.canvas(for: name).activeTab else {
			return false
		}
		requestCloseTab(tab, vm: name)
		return true
	}

	// MARK: - Asking before a session ends (H42)

	public static let skipSSHCloseQuestionKey = "MachmanSkipSSHCloseQuestion"

	public static func closeSessionTitle(_ name: String) -> String {
		"Close \u{201C}\(name)\u{201D}?"
	}

	public static let closeSessionMessage = "The SSH session ends."

	// The close a user asked for: at once, or after the question when closeAsks says so.
	// `window` is the torn tab whose window asked (nil: the main window): the question
	// shows there.
	public func requestCloseTab(_ tab: VMPaneTab, vm: String, from window: TornTab? = nil) {
		guard closeAsks(tab, vm: vm), case .ssh(let ref) = tab else {
			closeTab(tab, vm: vm)
			return
		}
		tabCloseQueue.enqueue(
			PendingTabClose(
				vm: vm, tab: tab, name: terminals.sshSessionName(vm: vm, ref: ref),
				window: window),
			duplicate: { $0.vm == $1.vm && $0.tab == $1.tab })
	}

	// Closing an SSH session whose ssh still runs ends a remote shell and its scrollback, so
	// it asks first unless “Don’t ask again” was ticked (C3). Serial tabs only disconnect —
	// the guest keeps running — and the configuration tab holds nothing; both close at once.
	public func closeAsks(_ tab: VMPaneTab, vm: String) -> Bool {
		guard case .ssh(let ref) = tab,
			terminals.sshController(vm: vm, ref: ref)?.connected == true else { return false }
		return sshCloseAskOverride
			?? !UserDefaults.standard.bool(forKey: Self.skipSSHCloseQuestionKey)
	}

	public var pendingTabClose: PendingTabClose? { tabCloseQueue.current }

	public func confirmTabClose(_ pending: PendingTabClose) {
		closeTab(pending.tab, vm: pending.vm)
	}

	// Take a tab off the canvas for its own window. The controller stays: the window adopts
	// it. The caller opens the window a turn later, once this mount is gone. The tab counts
	// as torn from here (T11): in the turns before the window appears, a row click or an
	// open must focus that window, not mount the tab in the canvas again.
	public func tearOff(_ tab: VMPaneTab, vm: String) -> TornTab {
		var canvas = canvases.canvas(for: vm)
		canvas.close(tab)
		canvases.setCanvas(canvas, for: vm)
		let torn = TornTab(vm: vm, tab: tab)
		tornTabs.open.insert(torn)
		tabClosed(tab, vm: vm)   // the next row click focuses the window
		return torn
	}

	// A tab's row goes with it, so the inspector stops showing a tab that closed. Every
	// path that takes a tab off a canvas (close, tear-off, torn-window close) reports here.
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

	// The tree mirrors the canvas (T8): when the shown VM's active tab CHANGES — ⇧⌘[ / ],
	// a close's fallback, a drag between panes; clicks select on their own (T23) — its row is
	// selected, so the inspector follows the tab the user is working in. Divider drags,
	// reorders, other VMs' canvases and renames (the incoming layouts lack the old key)
	// leave the selection alone, and so does an empty canvas filling with its
	// configuration tab: that is the canvas's own fallback as a VM is shown, part of a VM
	// switch. Nothing reopens: selecting a row never opens it (T7). Runs inside the
	// store's willSet, so canvases still holds the old layouts.
	func canvasesWillChange(_ incoming: [String: CanvasState]) {
		guard let name = selectedName else { return }
		let old = canvases.canvas(for: name)
		let before = old.activeTab
		guard let after = incoming[name]?.activeTab, after != before else { return }
		if after == .config && old.allOpenTabs.isEmpty { return }
		let node = Self.treeNode(for: after)
		if treeSelection != [node] { treeSelection = [node] }
	}

	// MARK: - Clicks (T23)

	// A click on a canvas tab: it becomes the active tab and its row is selected — even when
	// it already was active. T8's sync runs only when the active tab changes, so clicking
	// the tab you were typing in, after selecting a disk, left the inspector on the disk.
	public func tabClicked(_ tab: VMPaneTab, vm: String) {
		var canvas = canvases.canvas(for: vm)
		if canvas.activeTab != tab {
			canvas.activate(tab)
			canvases.setCanvas(canvas, for: vm)
		}
		selectRow(for: tab, vm: vm)
	}

	// A click in a pane, on its strip or anywhere in its content: it becomes the active pane
	// (where tree opens and ⌘-cycling land, and the one keystrokes go to) and its tab's row
	// is selected.
	public func paneClicked(_ paneID: UUID, vm: String) {
		var canvas = canvases.canvas(for: vm)
		if canvas.activePaneID != paneID, canvas.panes.contains(where: { $0.id == paneID }) {
			canvas.activatePane(paneID)
			canvases.setCanvas(canvas, for: vm)
		}
		guard let tab = canvases.canvas(for: vm).activeTab else { return }
		selectRow(for: tab, vm: vm)
	}

	private func selectRow(for tab: VMPaneTab, vm: String) {
		guard vm == selectedName else { return }
		let node = Self.treeNode(for: tab)
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

	// "Session N": the next number above every name still showing in a window — open
	// sessions (torn ones included) under their current names, plus the windows the system
	// restored after a relaunch, which hold no session (not listed, T20) but still show
	// their birth name in the title (T13).
	public func nextSSHSessionTitle(vm: String) -> String {
		let prefix = "Session "
		let restored = tornTabs.open.compactMap { torn -> SSHSessionRef? in
			guard torn.vm == vm, case .ssh(let ref) = torn.tab,
				terminals.sshController(vm: vm, ref: ref) == nil else { return nil }
			return ref
		}
		let taken = (openSSHSessions(vm: vm) + restored).compactMap { ref -> Int? in
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

// A connected SSH session waiting on “Close “Session 1”?” (H42); `window` is the torn tab
// whose window asked, nil for the main window.
public struct PendingTabClose: Identifiable, Equatable {
	public let id = UUID()
	public let vm: String
	public let tab: VMPaneTab
	public let name: String
	public let window: TornTab?
}
