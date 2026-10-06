//
//  ToastCenter.swift
//  MachmanDesktopCore
//
//  The bottom-right toast stack (Q10), its own observable: a push (a keyed slot replaces
//  what shows in place), the pointer's hold, the timed expiry from the user's setting and
//  the cap of five. Only the overlay observes it, so a toast coming and going re-renders the
//  corner, not the window and its menus (P9). One per view model: a reconnect starts a
//  fresh stack, as before. VMListViewModel+Toasts.swift keeps the view model's toast API on
//  top of it.
//

import Foundation
import SwiftUI
import MachmanUI

@MainActor
public final class ToastCenter: ObservableObject {
	public static let secondsKey = "MachmanToastSeconds"
	public static let defaultSeconds = 4.0
	public static let maxToasts = 5

	@Published public private(set) var toasts: [MachmanToast] = []
	// Toasts the pointer rests on stay until it leaves, then live a fresh lifetime (F6), so a
	// long warning can be read; each timed toast's expiry is tracked to restart it.
	private var held: Set<UUID> = []
	private var expiries: [UUID: Task<Void, Never>] = [:]
	// Tests shorten a toast's life without touching the user's setting.
	var lifetimeOverride: Duration?

	public init() {}

	private var lifetime: Duration {
		if let lifetimeOverride { return lifetimeOverride }
		let stored = UserDefaults.standard.double(forKey: Self.secondsKey)
		return .seconds(stored > 0 ? stored : Self.defaultSeconds)
	}

	// A toast; its lifetime comes from the user's setting. A `key` makes it a named slot:
	// pushing the same key replaces what is showing IN PLACE, so a state that moves
	// (waiting → ready) reads as one toast changing rather than three piling up. `spinner`
	// shows an indeterminate indicator instead of the symbol, and `sticky` skips the timer
	// entirely — for waits that end with another push.
	public func push(
		symbol: String, message: String, tint: Color? = nil,
		key: String? = nil, spinner: Bool = false, sticky: Bool = false
	) {
		let toast = MachmanToast(
			symbol: symbol, message: message, tint: tint,
			key: key, spinner: spinner, sticky: sticky)
		if let key, let existing = toasts.firstIndex(where: { $0.key == key }) {
			let replaced = toasts[existing].id
			let wasHeld = held.contains(replaced)
			toasts[existing] = toast
			forget(replaced)
			// The pointer still rests on the slot: the hold moves to what replaced it.
			if wasHeld { held.insert(toast.id) }
		} else {
			toasts.append(toast)
			// A burst keeps the newest few: the oldest timed toast goes first, waits stay.
			while toasts.count > Self.maxToasts,
				let oldest = toasts.firstIndex(where: { !$0.sticky }) {
				forget(toasts.remove(at: oldest).id)
			}
		}
		guard !sticky else { return }
		scheduleExpiry(toast.id)
	}

	// The overlay's hover: a held toast outlives its timer; letting go restarts it in full.
	public func hold(_ id: UUID, _ isHeld: Bool) {
		if isHeld {
			held.insert(id)
		} else if held.remove(id) != nil,
			toasts.contains(where: { $0.id == id && !$0.sticky }) {
			scheduleExpiry(id)
		}
	}

	// Retire a named slot without replacing it (the wait ended in nothing worth saying).
	public func dismiss(key: String) {
		for toast in toasts where toast.key == key { forget(toast.id) }
		toasts.removeAll { $0.key == key }
	}

	private func scheduleExpiry(_ id: UUID) {
		expiries[id]?.cancel()
		let lifetime = lifetime
		expiries[id] = Task { [weak self] in
			try? await Task.sleep(for: lifetime)
			guard !Task.isCancelled, let self else { return }
			self.expiries[id] = nil
			// Held: the release starts a fresh lifetime.
			guard !self.held.contains(id) else { return }
			self.toasts.removeAll { $0.id == id }
		}
	}

	// A toast that left the stack by any other way than its own timer.
	private func forget(_ id: UUID) {
		expiries.removeValue(forKey: id)?.cancel()
		held.remove(id)
	}
}
