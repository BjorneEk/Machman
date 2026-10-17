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
	let viewModel: VMListViewModel
	// The questions live in the prompt center, beside every other prompt (Q31).
	@ObservedObject private var prompts: PromptCenter
	// The torn tab whose window this is; nil in the main window.
	let window: TornTab?
	@AppStorage(VMListViewModel.skipSSHCloseQuestionKey) private var skipQuestion = false

	init(viewModel: VMListViewModel, window: TornTab?) {
		self.viewModel = viewModel
		self.prompts = viewModel.prompts
		self.window = window
	}

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
			set: { if !$0 { viewModel.isTabClosePresented = false } })
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
