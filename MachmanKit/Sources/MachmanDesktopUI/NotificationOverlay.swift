//
//  NotificationOverlay.swift
//  MachmanDesktopUI
//
//  The bottom-right feedback corner (1.0.4 UI): status toasts (a stale VM list) and transient
//  toasts (engine warnings) over persistent progress cards — the daemon's live operations
//  plus running macOS installs, with ETA math from ProgressETA. A running card's ✕ cancels
//  (op.cancel / vm.install.cancel); finished operations linger a few seconds showing their
//  outcome, then prune from the store, and their ✕ only dismisses them.
//

import SwiftUI
import MachmanUI
import MachmanAPI
import MachmanDesktopCore

struct NotificationOverlay: View {
	@ObservedObject var viewModel: VMListViewModel
	@ObservedObject var operations: OperationsStore
	// The toast stack publishes on its own, so a toast re-renders only this corner (Q10).
	@ObservedObject private var toasts: ToastCenter

	init(viewModel: VMListViewModel, operations: OperationsStore) {
		self.viewModel = viewModel
		self.operations = operations
		self.toasts = viewModel.toastCenter
	}

	var body: some View {
		ToastStack(
			toasts: viewModel.statusToasts + toasts.toasts,
			progress: cards,
			dismissProgress: viewModel.closeProgressCard,
			hoverToast: toasts.hold)
	}

	private var cards: [ProgressCardModel] {
		var cards = operations.operations.map { op in
			ProgressCardModel(
				id: op.id,
				title: op.displayTitle,
				symbol: op.displaySymbol,
				phase: phase(for: op),
				fraction: op.fraction,
				etaSeconds: op.etaSeconds(now: MachmanClock.now()),
				finished: op.isFinished,
				cancellable: op.isCancellable)
		}
		// Running macOS installs ride the richer install-phase flow, not OperationInfo.
		for (vm, phase) in operations.installPhases {
			switch phase.kind {
			case .resolving, .downloading, .installing:
				cards.append(ProgressCardModel(
					id: VMListViewModel.installCardPrefix + vm,
					title: "\(vm) — Installing macOS",
					symbol: MachmanSymbols.bootMacTab,
					phase: phase.displayLabel,
					fraction: phase.progress?.fraction,
					etaSeconds: phase.etaSeconds(now: MachmanClock.now())))
			default:
				break
			}
		}
		return cards
	}

	// MARK: - Operation mapping (title and symbol: OperationInfo+Display)

	private func phase(for op: OperationInfo) -> String {
		if let outcome = op.outcomeText { return outcome }
		if let done = op.completedBytes, let total = op.totalBytes, total > 0 {
			// Binary units, like every other size (decision 14).
			let f = ByteSize.display(UInt64(clamping: done))
			let t = ByteSize.display(UInt64(clamping: total))
			return "\(f) of \(t)"
		}
		return "Working…"
	}
}
