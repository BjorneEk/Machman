//
//  TabCloseQuestion.swift
//  MachmanDesktopUI
//
//  “Close “Session 1”?” — asked before a connected SSH session's tab closes (H42, choice C3),
//  with a “Don’t ask again” checkbox. Each window shows only the questions it asked: the main
//  window its own, a torn-off window those for its session (PendingTabClose.window).
//

import SwiftUI
import MachmanUI
import MachmanDesktopCore

struct TabCloseQuestion: ViewModifier {
	@ObservedObject var viewModel: VMListViewModel
	// The torn tab whose window this is; nil in the main window.
	let window: TornTab?
	@AppStorage(VMListViewModel.skipSSHCloseQuestionKey) private var skipQuestion = false

	func body(content: Content) -> some View {
		content
			.confirmationDialog(
				VMListViewModel.closeSessionTitle(viewModel.pendingTabClose?.name ?? ""),
				isPresented: presented, presenting: viewModel.pendingTabClose
			) { pending in
				Button("Close Session", role: .destructive) { viewModel.confirmTabClose(pending) }
				Button("Cancel", role: .cancel) {}
			} message: { _ in
				Text(VMListViewModel.closeSessionMessage)
			}
			.dialogSuppressionToggle("Don’t ask again", isSuppressed: $skipQuestion)
	}

	private var presented: Binding<Bool> {
		Binding(
			get: { viewModel.isTabClosePresented && viewModel.pendingTabClose?.window == window },
			set: { viewModel.isTabClosePresented = $0 })
	}
}

private struct TornTabWindowKey: EnvironmentKey {
	static let defaultValue: TornTab? = nil
}

extension EnvironmentValues {
	// The torn tab whose window a view is in (nil in the main window): where a question it
	// asks is shown.
	var tornTabWindow: TornTab? {
		get { self[TornTabWindowKey.self] }
		set { self[TornTabWindowKey.self] = newValue }
	}
}
