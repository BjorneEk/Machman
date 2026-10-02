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
			dismissProgress: viewModel.closeProgressCard)
	}

	private var cards: [ProgressCardModel] {
		var cards = operations.operations.map { op in
			ProgressCardModel(
				id: op.id,
				title: title(for: op),
				symbol: symbol(for: op),
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

	// MARK: - Operation mapping

	private func title(for op: OperationInfo) -> String {
		if let vm = op.vm { return "\(vm) — \(op.label)" }
		return op.label
	}

	private func symbol(for op: OperationInfo) -> String {
		switch op.kind {
		case OperationInfo.Kind.copyVM: return MachmanSymbols.duplicateVM
		case OperationInfo.Kind.importDisk, OperationInfo.Kind.promoteDisk:
			return MachmanSymbols.diskStorage
		case OperationInfo.Kind.shadowBuild, OperationInfo.Kind.safeSave:
			return MachmanSymbols.safe
		case OperationInfo.Kind.kernelImport: return MachmanSymbols.initramfs
		case OperationInfo.Kind.rosettaInstall: return MachmanSymbols.deviceRosetta
		default: return MachmanSymbols.more
		}
	}

	private func phase(for op: OperationInfo) -> String {
		switch op.state {
		case OperationInfo.State.succeeded: return "Done"
		case OperationInfo.State.failed: return op.message ?? "Failed"
		case OperationInfo.State.cancelled: return "Canceled"
		default:
			if let done = op.completedBytes, let total = op.totalBytes, total > 0 {
				let f = ByteCountFormatter.string(
					fromByteCount: done, countStyle: .file)
				let t = ByteCountFormatter.string(
					fromByteCount: total, countStyle: .file)
				return "\(f) of \(t)"
			}
			return "Working…"
		}
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
