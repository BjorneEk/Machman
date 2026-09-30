//
//  TornTabRegistry.swift
//  MachmanDesktop
//
//  Window bookkeeping for canvas tabs torn off into their own windows (TornTabWindowView):
//  which are open, and the close/reopen orders the view model's list reconcile posts to them.
//

import Foundation
import MachmanUI

// Which torn tabs currently have a window — the double-mount guard: opening a torn tab
// from the tree/canvas FOCUSES its window (openWindow dedups by value) instead of
// mounting the same TerminalView a second time. Pure window bookkeeping, so a shared
// registry beats threading one more store through every init.
@MainActor
final class TornTabRegistry: ObservableObject {
	// An instruction for one open torn window, posted by the view model (the list-refresh
	// reconcile) and resolved by the window itself — dismissWindow is a view environment
	// action nothing else can call. The window consumes its order as it acts, so a stale
	// order can never re-fire against a future window with the same payload.
	enum Order: Equatable {
		case close   // the tab's backing VM or port is gone — the window's teardown is real
		// The VM was renamed: swap to a window keyed by the new name. The controllers were
		// already re-keyed by the rename migration, so the successor window ADOPTS the live
		// session — the old window's teardown under the old key is a deliberate no-op.
		case reopen(as: TornTab)
	}

	static let shared = TornTabRegistry()
	@Published var open: Set<TornTab> = []
	@Published var orders: [TornTab: Order] = [:]

	// The app uses `shared`; tests make their own so parallel tests never share one.
	init() {}

	func isOpen(vm: String, tab: VMPaneTab) -> Bool {
		open.contains(TornTab(vm: vm, tab: tab))
	}
}
