//
//  NextTurnCoalescer.swift
//  MachmanDesktopCore
//
//  Runs an action once on the next main-queue turn, however often it is asked before then
//  (Q32). objectWillChange fires before a change lands, and a burst — several fields of a
//  profile, a window resigning key as the next becomes key — fires it many times: whoever
//  reacts reads the settled state a turn later, once. The menus (MenuModel), the terminal
//  registry's profile follow (TerminalSessions) and the focus watcher (FocusMonitor) share it.
//

import Foundation

@MainActor
final class NextTurnCoalescer {
	private let action: @MainActor () -> Void
	private var scheduled = false

	init(_ action: @escaping @MainActor () -> Void) {
		self.action = action
	}

	func schedule() {
		guard !scheduled else { return }
		scheduled = true
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }
			self.scheduled = false
			self.action()
		}
	}
}
