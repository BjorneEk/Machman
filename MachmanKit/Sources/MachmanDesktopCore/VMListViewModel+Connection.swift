//
//  VMListViewModel+Connection.swift
//  MachmanDesktopCore
//
//  What the connection's state says in the window corner: status toasts that live exactly as
//  long as the state they report, beside the timed ones.
//

import Foundation
import MachmanUI

extension VMListViewModel {
	public static let listProblemToastID = UUID()
	public static let listProblemMessage = "Couldn't refresh the VM list — retrying"

	// The list on screen may be stale: shown until a refresh lands (P13).
	public var statusToasts: [MachmanToast] {
		guard store.listProblem != nil else { return [] }
		return [MachmanToast(
			id: Self.listProblemToastID, symbol: MachmanSymbols.warning,
			message: Self.listProblemMessage, tint: MachmanColors.warning,
			spinner: true, sticky: true)]
	}
}
