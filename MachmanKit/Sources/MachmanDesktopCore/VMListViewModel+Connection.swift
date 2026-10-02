//
//  VMListViewModel+Connection.swift
//  MachmanDesktopCore
//
//  What the connection's state says to the user: status toasts in the window corner that
//  live exactly as long as the state they report, and — after a reconnect — what the lost
//  connection cut off.
//

import Foundation
import MachmanUI
import MachmanClient

extension VMListViewModel {
	public static let listProblemToastID = UUID()
	public static let listProblemMessage = "Couldn’t refresh the VM list — retrying"

	// The list on screen may be stale: shown until a refresh lands (P13).
	public var statusToasts: [MachmanToast] {
		guard store.listProblem != nil else { return [] }
		return [MachmanToast(
			id: Self.listProblemToastID, symbol: MachmanSymbols.warning,
			message: Self.listProblemMessage, tint: MachmanColors.warning,
			spinner: true, sticky: true)]
	}

	// After a reconnect: one alert naming the user's actions that were still in flight when
	// the connection dropped (P12). The old view model — and any alert it would have shown
	// for them — went with the connection; this one says it instead.
	public func announceInterrupted(_ calls: [InterruptedCall]) {
		guard let message = InterruptedActions.message(calls) else { return }
		present(title: Self.connectionLostTitle, message: message)
	}

	public static let connectionLostTitle = "The connection to Machman Agent was lost"
}
