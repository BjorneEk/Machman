//
//  WindowPrompts.swift
//  MachmanDesktopUI
//
//  The alerts and questions PromptCenter queues (PR25), in whichever window should show them
//  (H40, C22, K8). The main window and each torn window carry this modifier; the center's
//  window claim decides which one shows the prompt showing now — for most, the window key
//  when it arrived, or the first to become key while it waits — so a refusal or a question
//  from a torn window shows in that window, never twice. It observes the center, not the view
//  model: a prompt coming and going re-renders this modifier only (P9). An error is its own
//  alert with the system's OK; every other prompt is drawn from its PromptContent, as an alert
//  or a confirmation dialog — except a session close, which TabCloseQuestion shows with its
//  “Don’t ask again” toggle (a suppression toggle would join every dialog drawn here).
//

import SwiftUI
import AppKit
import MachmanDesktopCore

struct WindowPrompts: ViewModifier {
	let viewModel: VMListViewModel
	@ObservedObject private var prompts: PromptCenter
	let window: CommandWindow
	@State private var isKey = false
	// The prompt this window holds, until it is dismissed.
	@State private var shown: UUID?

	init(viewModel: VMListViewModel, window: CommandWindow) {
		self.viewModel = viewModel
		self.prompts = viewModel.prompts
		self.window = window
	}

	func body(content: Content) -> some View {
		content
			.background(KeyWindowWatcher { key in
				isKey = key
				claim()
			})
			.onChange(of: prompts.current?.id, initial: true) { claim() }
			.onDisappear {
				prompts.release(window)
				shown = nil
			}
			.modifier(ErrorAlert(error: shownError, isPresented: presented { $0.isError }))
			.modifier(QuestionAlert(
				content: shownQuestion(.alert),
				isPresented: presented { !$0.isError && $0.style == .alert }))
			.modifier(QuestionDialog(
				content: shownQuestion(.dialog), isPresented: presented { $0.style == .dialog }))
	}

	// The prompt this window shows now, if any.
	private var shownPrompt: Prompt? {
		guard let shown, let current = prompts.current, current.id == shown else { return nil }
		return current
	}

	private var shownError: PresentedError? {
		if case .error(let error)? = shownPrompt?.kind { return error }
		return nil
	}

	private func shownQuestion(_ style: PromptContent.Style) -> PromptContent? {
		guard let prompt = shownPrompt, !prompt.isError, prompt.style == style else { return nil }
		return prompt.content(for: viewModel)
	}

	// Shown while this window holds a prompt `matching`; a dismissal frees the window and
	// shows the next prompt after this one has animated out.
	private func presented(_ matching: @escaping (Prompt) -> Bool) -> Binding<Bool> {
		Binding(
			get: { shownPrompt.map(matching) ?? false },
			set: { showing in
				guard !showing, let id = shown else { return }
				shown = nil
				prompts.release(window)
				prompts.dismiss(id)
			})
	}

	private func claim() {
		guard let current = prompts.current, current.kind.tabClose == nil else {
			shown = nil
			return
		}
		let mine = prompts.shows(
			current.id, in: window, isKey: isKey, anyWindowKey: NSApp.keyWindow != nil)
		shown = mine ? current.id : nil
	}
}

extension Prompt {
	fileprivate var isError: Bool { kind.error != nil }
}

// A failure: its title and message, and the system's own OK.
private struct ErrorAlert: ViewModifier {
	let error: PresentedError?
	let isPresented: Binding<Bool>

	func body(content: Content) -> some View {
		content.alert(error?.title ?? "Error", isPresented: isPresented, presenting: error) { _ in
			// Empty: SwiftUI supplies the default OK button.
		} message: { error in
			Text(error.message)
		}
	}
}

// A question drawn as an alert: its buttons and what each does come from its PromptContent.
private struct QuestionAlert: ViewModifier {
	let content: PromptContent?
	let isPresented: Binding<Bool>

	func body(content view: Content) -> some View {
		view.alert(content?.title ?? "", isPresented: isPresented, presenting: content) { shown in
			ForEach(shown.choices) { choice in
				Button(choice.title, role: choice.role?.buttonRole) { choice.perform() }
			}
		} message: { shown in
			Text(shown.message)
		}
	}
}

// A question drawn as a confirmation dialog, from its PromptContent.
private struct QuestionDialog: ViewModifier {
	let content: PromptContent?
	let isPresented: Binding<Bool>

	func body(content view: Content) -> some View {
		view.confirmationDialog(
			content?.title ?? "", isPresented: isPresented, presenting: content
		) { shown in
			ForEach(shown.choices) { choice in
				Button(choice.title, role: choice.role?.buttonRole) { choice.perform() }
			}
		} message: { shown in
			Text(shown.message)
		}
	}
}

extension PromptContent.Role {
	var buttonRole: ButtonRole {
		switch self {
		case .destructive: return .destructive
		case .cancel: return .cancel
		}
	}
}

// Tells its view whether the window holding it is key, now and at every change (a
// WindowWatcher configuration).
private struct KeyWindowWatcher: View {
	let changed: (Bool) -> Void

	var body: some View {
		WindowWatcher(handler: changed) { view, window in
			// Not inside the view update that moved this view.
			DispatchQueue.main.async { [weak view] in
				view?.handler(view?.window?.isKeyWindow ?? false)
			}
			return window.observe(
				[NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
			) { [weak view] _ in
				view?.handler(view?.window?.isKeyWindow ?? false)
			}
		}
	}
}
