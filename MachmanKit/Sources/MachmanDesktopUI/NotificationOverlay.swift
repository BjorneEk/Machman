//
//  NotificationOverlay.swift
//  MachmanDesktopUI
//
//  The bottom-right feedback corner (1.0.4 UI): status toasts (a stale VM list) and transient
//  toasts (engine warnings) over persistent progress cards — the daemon's live operations
//  plus running macOS installs, as OperationsStore.progressCards says them (Q33, with ETA
//  math from ProgressETA). A running card's ✕ cancels (op.cancel / vm.install.cancel);
//  finished operations linger a few seconds showing their outcome, then prune from the
//  store, and their ✕ only dismisses them. An install's card leaves when its phase ends,
//  saying the outcome to VoiceOver (H56, review F16).
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
	@Environment(\.toastAnnouncer) private var announcer

	init(viewModel: VMListViewModel, operations: OperationsStore) {
		self.viewModel = viewModel
		self.operations = operations
		self.toasts = viewModel.toastCenter
	}

	var body: some View {
		ToastStack(
			toasts: viewModel.statusToasts + toasts.toasts,
			progress: operations.progressCards(now: MachmanClock.now()),
			dismissProgress: viewModel.closeProgressCard,
			hoverToast: toasts.hold)
		.onChange(of: operations.installPhases) { old, new in
			for announcement in InstallPhase.announcements(from: old, to: new) {
				announcer.post(announcement)
			}
		}
	}
}
