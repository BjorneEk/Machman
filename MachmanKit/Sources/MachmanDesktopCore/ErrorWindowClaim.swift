//
//  ErrorWindowClaim.swift
//  MachmanDesktopCore
//
//  Which window shows the error alert (H40, C22). VMListViewModel queues failures one at a
//  time; the main window and every torn window can show one, and this decides which: the
//  window that is key when the error arrives, or the first to become key while it waits, so
//  a refusal from a torn window's inspector shows in that window and never in two. While no
//  window is key (Machman in the background) the main window takes it, as it always did.
//  The claim is keyed by the error, so one made before a reconnect never matches the new
//  view model's errors.
//

import Foundation

public struct ErrorWindowClaim: Equatable {
	public private(set) var error: UUID?
	public private(set) var window: CommandWindow?

	public init() {}

	// Whether `window` shows `error` now: it holds it already, or takes it — being key, or
	// being the main window while no window is.
	public mutating func claims(
		_ error: UUID?, for window: CommandWindow, isKey: Bool, anyWindowKey: Bool
	) -> Bool {
		guard let error else { return false }
		if self.error == error { return self.window == window }
		guard isKey || (window == .main && !anyWindowKey) else { return false }
		self.error = error
		self.window = window
		return true
	}

	// `window` closed or its alert was dismissed: what it held is free for the next taker.
	public mutating func release(_ window: CommandWindow) {
		guard self.window == window else { return }
		error = nil
		self.window = nil
	}
}
