//
//  VMListViewModel+Operations.swift
//  MachmanDesktopCore
//
//  The progress cards' ✕: it cancels work that is still running and only dismisses a card
//  that already shows its outcome (decision 13, F2).
//

import Foundation
import MachmanAPI

extension VMListViewModel {
	// Running macOS installs ride as cards keyed "install:<vm>".
	public static let installCardPrefix = "install:"

	public func closeProgressCard(_ id: String) {
		if id.hasPrefix(Self.installCardPrefix) {
			cancelInstall(String(id.dropFirst(Self.installCardPrefix.count)))
		} else if operationsStore.operations.contains(where: { $0.id == id && $0.isFinished }) {
			operationsStore.dismiss(id: id)
		} else {
			cancelOperation(id: id)
		}
	}
}
