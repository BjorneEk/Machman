//
//  VMListViewModel+Toasts.swift
//  MachmanDesktopCore
//
//  The view model's toasts: the stack itself is its ToastCenter (push, hold, expiry, the
//  cap), which only the overlay observes (Q10); these keep every caller's API. Problem toasts
//  also land in the activity list (PR5): the toast says it now, the list keeps it.
//  Confirmations, the SSH connecting slot and the list-stale status stay toasts only.
//

import Foundation
import SwiftUI
import MachmanUI
import MachmanAPI

extension VMListViewModel {
	public static let toastSecondsKey = ToastCenter.secondsKey
	public static let defaultToastSeconds = ToastCenter.defaultSeconds
	public static let maxToasts = ToastCenter.maxToasts

	public var toasts: [MachmanToast] { toastCenter.toasts }

	// Tests shorten a toast's life without touching the user's setting.
	var toastLifetimeOverride: Duration? {
		get { toastCenter.lifetimeOverride }
		set { toastCenter.lifetimeOverride = newValue }
	}

	// A bottom-right toast (ToastCenter.push): a `key` makes it a slot replaced in place,
	// `spinner` and `sticky` make it a wait that ends with another push.
	public func pushToast(
		symbol: String, message: String, tint: Color? = nil,
		key: String? = nil, spinner: Bool = false, sticky: Bool = false
	) {
		toastCenter.push(
			symbol: symbol, message: message, tint: tint, key: key, spinner: spinner,
			sticky: sticky)
	}

	public func holdToast(_ id: UUID, _ held: Bool) {
		toastCenter.hold(id, held)
	}

	public func dismissToast(key: String) {
		toastCenter.dismiss(key: key)
	}

	// MARK: - Problems (PR5)

	public var activity: ActivityLog { operationsStore.activity }

	func pushProblem(
		symbol: String, message: String, tint: Color? = nil, vm: String, detail: String,
		severity: ActivityEntry.Severity
	) {
		pushToast(symbol: symbol, message: message, tint: tint)
		activity.record(.problem(
			vm: vm, detail: detail, symbol: symbol, severity: severity, at: MachmanClock.now()))
	}
}
