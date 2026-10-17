//
//  ProgressCards.swift
//  MachmanDesktopCore
//
//  What the corner's progress cards say (Q33), decided here instead of in the overlay's body,
//  so the headless tests read it: the daemon's operations in the order they arrived, then the
//  running macOS installs by VM name — never a Dictionary's order — each with its phase text
//  (the bytes so far, “Working…” or the outcome), its fraction and ETA, and whether its ✕
//  cancels or only dismisses. Titles and symbols come from OperationInfo+Display and
//  InstallPhase+Display.
//

import Foundation
import MachmanAPI
import MachmanUI

extension OperationsStore {
	public func progressCards(now: Date) -> [ProgressCardModel] {
		let running = operations.map { op in
			ProgressCardModel(
				id: op.id, title: op.displayTitle, symbol: op.displaySymbol,
				phase: Self.phase(of: op), fraction: op.fraction,
				etaSeconds: op.etaSeconds(now: now), finished: op.isFinished,
				cancellable: op.isCancellable)
		}
		// Running macOS installs ride the richer install-phase flow, not OperationInfo.
		let installs = installPhases
			.filter { $0.value.isRunning }
			.sorted { $0.key < $1.key }
			.map { vm, phase in
				ProgressCardModel(
					id: VMListViewModel.installCardPrefix + vm,
					title: InstallPhase.cardTitle(vm: vm), symbol: MachmanSymbols.bootMacTab,
					phase: phase.displayLabel, fraction: phase.progress?.fraction,
					etaSeconds: phase.etaSeconds(now: now))
			}
		return running + installs
	}

	// An operation's line under its title: its outcome once it has one, else the bytes so far
	// in binary units, like every other size (decision 14), else that it is working.
	static func phase(of op: OperationInfo) -> String {
		if let outcome = op.outcomeText { return outcome }
		if let done = op.completedBytes, let total = op.totalBytes, total > 0 {
			let f = ByteSize.display(UInt64(clamping: done))
			let t = ByteSize.display(UInt64(clamping: total))
			return "\(f) of \(t)"
		}
		return "Working…"
	}
}
