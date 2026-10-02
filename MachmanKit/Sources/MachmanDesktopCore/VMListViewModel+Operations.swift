//
//  VMListViewModel+Operations.swift
//  MachmanDesktopCore
//
//  The progress cards' ✕: it cancels work that is still running and only dismisses a card
//  that already shows its outcome (decision 13, F2). Running work the engine can't cancel
//  shows no ✕ at all (F7).
//

import Foundation
import MachmanAPI

extension VMListViewModel {
	// Running macOS installs ride as cards keyed "install:<vm>".
	public static let installCardPrefix = "install:"

	public func closeProgressCard(_ id: String) {
		if id.hasPrefix(Self.installCardPrefix) {
			cancelInstall(String(id.dropFirst(Self.installCardPrefix.count)))
			return
		}
		let op = operationsStore.operations.first { $0.id == id }
		if op?.isFinished == true {
			operationsStore.dismiss(id: id)
		} else if op?.isCancellable == false {
			// Its card shows no ✕; a stale click must not raise "cannot be cancelled".
			return
		} else {
			cancelOperation(id: id)
		}
	}

	public func cancelOperation(id: String) {
		perform(
			"Canceling the operation",
			// It ended meanwhile; its card already shows how.
			recover: { _, error in error.code == .notFound }
		) { try await $0.cancelOperation(id: id) }
	}
}
