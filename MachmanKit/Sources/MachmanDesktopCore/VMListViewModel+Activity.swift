//
//  VMListViewModel+Activity.swift
//  MachmanDesktopCore
//
//  The activity list as the views reach it, and the desktop's problem toasts that also
//  land in it (PR5): the toast says it now, the list keeps it. Confirmations, the SSH
//  connecting slot and the list-stale status stay toasts only.
//

import SwiftUI
import MachmanAPI

extension VMListViewModel {
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
