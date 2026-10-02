//
//  NotificationOverlay.swift
//  MachmanDesktopUI
//
//  The bottom-right feedback corner (1.0.4 UI): status toasts (a stale VM list) and transient
//  toasts (engine warnings) over persistent progress cards — the daemon's live operations
//  plus running macOS installs, with client-side ETA math. A running card's ✕ cancels
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

	var body: some View {
		ToastStack(
			toasts: viewModel.statusToasts + viewModel.toasts,
			progress: cards,
			dismissProgress: viewModel.closeProgressCard,
			hoverToast: viewModel.holdToast)
	}

	private var cards: [ProgressCardModel] {
		var cards = operations.operations.map { op in
			ProgressCardModel(
				id: op.id,
				title: op.displayTitle,
				symbol: op.displaySymbol,
				phase: phase(for: op),
				fraction: op.fraction,
				etaSeconds: eta(for: op),
				finished: op.isFinished,
				cancellable: op.isCancellable)
		}
		// Running macOS installs ride the richer install-phase flow, not OperationInfo.
		for (vm, phase) in operations.installPhases {
			switch phase.kind {
			case .resolving, .downloading, .installing:
				cards.append(ProgressCardModel(
					id: VMListViewModel.installCardPrefix + vm,
					title: "Installing macOS — \(vm)",
					symbol: MachmanSymbols.bootMacTab,
					phase: installPhaseLabel(phase),
					fraction: phase.progress?.fraction,
					etaSeconds: installETA(phase)))
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

	// ETA is consumer math: elapsed rate over remaining bytes (nil until measurable).
	private func eta(for op: OperationInfo) -> Double? {
		guard op.state == OperationInfo.State.running,
			let done = op.completedBytes, let total = op.totalBytes,
			done > 0, total > done else { return nil }
		let elapsed = Date().timeIntervalSince(op.startedAt)
		guard elapsed > 1 else { return nil }
		let rate = Double(done) / elapsed
		guard rate > 0 else { return nil }
		return Double(total - done) / rate
	}

	private func installPhaseLabel(_ phase: InstallPhase) -> String {
		let version = phase.version.map { " macOS \($0)" } ?? ""
		switch phase.kind {
		case .resolving: return "Resolving\(version)…"
		case .downloading: return "Downloading\(version)…"
		default: return "Installing\(version)…"
		}
	}

	private func installETA(_ phase: InstallPhase) -> Double? {
		guard phase.kind == .downloading,
			let progress = phase.progress,
			let done = progress.completedBytes, let total = progress.totalBytes,
			done > 0, total > done,
			let started = phase.downloadStartedAt else { return nil }
		let elapsed = Date().timeIntervalSince(started)
		guard elapsed > 1 else { return nil }
		let rate = Double(done) / elapsed
		guard rate > 0 else { return nil }
		return Double(total - done) / rate
	}
}
