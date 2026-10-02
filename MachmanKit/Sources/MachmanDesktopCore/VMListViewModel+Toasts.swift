//
//  VMListViewModel+Toasts.swift
//  MachmanDesktopCore
//
//  The bottom-right toast stack: a push (a keyed slot replaces what shows in place), the
//  pointer's hold, the timed expiry from the user's setting and the cap of five. Problem
//  toasts also land in the activity list (PR5): the toast says it now, the list keeps it.
//  Confirmations, the SSH connecting slot and the list-stale status stay toasts only. The
//  stack's stored state sits in the class body (VMListViewModel.swift).
//

import Foundation
import SwiftUI
import MachmanUI
import MachmanAPI

extension VMListViewModel {
	public static let toastSecondsKey = "MachmanToastSeconds"
	public static let defaultToastSeconds = 4.0
	public static let maxToasts = 5

	private var toastLifetime: Duration {
		if let toastLifetimeOverride { return toastLifetimeOverride }
		let stored = UserDefaults.standard.double(forKey: Self.toastSecondsKey)
		return .seconds(stored > 0 ? stored : Self.defaultToastSeconds)
	}

	// A bottom-right toast; lifetime comes from the user's setting. A `key` makes it a
	// named slot: pushing the same key replaces what is showing IN PLACE, so a state that
	// moves (waiting → ready) reads as one toast changing rather than three piling up.
	// `spinner` shows an indeterminate indicator instead of the symbol, and `sticky` skips
	// the timer entirely — for waits that end with another push.
	public func pushToast(
		symbol: String, message: String, tint: Color? = nil,
		key: String? = nil, spinner: Bool = false, sticky: Bool = false
	) {
		let toast = MachmanToast(
			symbol: symbol, message: message, tint: tint,
			key: key, spinner: spinner, sticky: sticky)
		if let key, let existing = toasts.firstIndex(where: { $0.key == key }) {
			let replaced = toasts[existing].id
			let wasHeld = heldToasts.contains(replaced)
			toasts[existing] = toast
			forgetToast(replaced)
			// The pointer still rests on the slot: the hold moves to what replaced it.
			if wasHeld { heldToasts.insert(toast.id) }
		} else {
			toasts.append(toast)
			// A burst keeps the newest few: the oldest timed toast goes first, waits stay.
			while toasts.count > Self.maxToasts,
				let oldest = toasts.firstIndex(where: { !$0.sticky }) {
				forgetToast(toasts.remove(at: oldest).id)
			}
		}
		guard !sticky else { return }
		scheduleToastExpiry(toast.id)
	}

	// The overlay's hover: a held toast outlives its timer; letting go restarts it in full.
	public func holdToast(_ id: UUID, _ held: Bool) {
		if held {
			heldToasts.insert(id)
		} else if heldToasts.remove(id) != nil,
			toasts.contains(where: { $0.id == id && !$0.sticky }) {
			scheduleToastExpiry(id)
		}
	}

	private func scheduleToastExpiry(_ id: UUID) {
		toastExpiries[id]?.cancel()
		let lifetime = toastLifetime
		toastExpiries[id] = Task { [weak self] in
			try? await Task.sleep(for: lifetime)
			guard !Task.isCancelled, let self else { return }
			self.toastExpiries[id] = nil
			// Held: the release starts a fresh lifetime.
			guard !self.heldToasts.contains(id) else { return }
			self.toasts.removeAll { $0.id == id }
		}
	}

	// A toast that left the stack by any other way than its own timer.
	private func forgetToast(_ id: UUID) {
		toastExpiries.removeValue(forKey: id)?.cancel()
		heldToasts.remove(id)
	}

	// Retire a named slot without replacing it (the wait ended in nothing worth saying).
	public func dismissToast(key: String) {
		for toast in toasts where toast.key == key { forgetToast(toast.id) }
		toasts.removeAll { $0.key == key }
	}

	// MARK: - Problems (PR5)

	public var activity: ActivityLog { operationsStore.activity }

	func pushProblem(
		symbol: String, message: String, tint: Color? = nil, vm: String, detail: String,
		severity: ActivityEntry.Severity
	) {
		pushToast(symbol: symbol, message: message, tint: tint)
		activity.record(.problem(
			vm: vm, detail: detail, symbol: symbol, severity: severity, at: Date()))
	}
}
