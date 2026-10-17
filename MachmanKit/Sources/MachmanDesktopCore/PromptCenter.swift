//
//  PromptCenter.swift
//  MachmanDesktopCore
//
//  Every one-at-a-time alert and question the desktop shows (PR25, Q31): one FIFO of typed
//  prompts beside the toast stack, observed only by the windows' presenting modifiers
//  (WindowPrompts), so a prompt coming and going re-renders no other view (P9). A prompt that
//  arrives while another shows waits its turn — none replaces another — and a dismissal shows
//  the next once the last has animated out. Where a prompt shows is its placement: the window
//  that is key when it arrives (C22, K8), claimed through PromptWindowClaim. Each kind's words
//  and buttons are decided here (PromptContent), so a new question is a new kind and touches
//  no view. One per view model, like the toasts: a reconnect starts a fresh queue, and what
//  the lost connection cut off is announced anew (P12).
//

import Foundation
import MachmanUI
import MachmanAPI

// One user-facing failure: title = what the user was doing, message = why it failed.
public struct PresentedError: Identifiable {
	public let id = UUID()
	public let title: String
	public let message: String
}

// A Force Stop that can't reach a VM whose vmhost doesn't answer, held so the alert can end
// its process instead — only after this second, explicit question (C9).
public struct PendingEndProcess: Identifiable {
	public let id = UUID()
	public let vm: String
	public var prompt: EndProcessPrompt { .forVM(vm) }
}

// A start refused with macConflict, held so the alert can retry it with force.
public struct PendingForceStart: Identifiable {
	public let id = UUID()
	public let name: String
	public let headless: Bool
	public let safe: Bool
	public let message: String
}

// Which window shows a prompt.
public enum PromptPlacement: Equatable {
	// The window key when it arrives, or the first to become key while it waits; the main
	// window while Machman is in the background (C22, K8).
	case keyWindow
	// That window only: the one the question was asked in.
	case window(CommandWindow)
}

public struct Prompt: Identifiable {
	public enum Kind {
		case error(PresentedError)
		case forceStart(PendingForceStart)
		case endProcess(PendingEndProcess)
	}

	public let id = UUID()
	public let kind: Kind

	public var placement: PromptPlacement {
		switch kind {
		case .error, .forceStart, .endProcess:
			return .keyWindow
		}
	}

	// What a window shows for the prompt: its words, and what each button does. An error is
	// an alert with the system's own OK.
	@MainActor
	public func content(for viewModel: VMListViewModel) -> PromptContent {
		switch kind {
		case .error(let error):
			return PromptContent(style: .alert, title: error.title, message: error.message)
		case .forceStart(let pending):
			return PromptContent(
				style: .alert, title: "MAC address conflict", message: pending.message,
				choices: [
					.init("Start Anyway") { [weak viewModel] in
						viewModel?.startVM(
							pending.name, headless: pending.headless, force: true,
							safe: pending.safe)
					},
					.init("Cancel", role: .cancel),
				])
		case .endProcess(let pending):
			let prompt = pending.prompt
			return PromptContent(
				style: .alert, title: prompt.title, message: prompt.message,
				choices: [
					.init(prompt.confirm, role: .destructive) { [weak viewModel] in
						viewModel?.endProcess(pending.vm)
					},
					.init(prompt.cancel, role: .cancel),
				])
		}
	}
}

// A prompt as a window shows it.
public struct PromptContent {
	public enum Style {
		case alert
		case dialog   // a confirmation dialog
	}

	public enum Role {
		case destructive
		case cancel
	}

	public struct Choice: Identifiable {
		public let title: String
		public let role: Role?
		public let perform: @MainActor () -> Void
		public var id: String { title }

		init(_ title: String, role: Role? = nil, perform: @escaping @MainActor () -> Void = {}) {
			self.title = title
			self.role = role
			self.perform = perform
		}
	}

	public let style: Style
	public let title: String
	public let message: String
	// Empty: the alert's own OK.
	public let choices: [Choice]

	init(style: Style, title: String, message: String, choices: [Choice] = []) {
		self.style = style
		self.title = title
		self.message = message
		self.choices = choices
	}
}

@MainActor
public final class PromptCenter: ObservableObject {
	// A dismissed alert or dialog animates out; the next one is presented after that, not
	// inside it.
	public static let representDelay: Duration = .milliseconds(350)

	@Published private var queue = PresentationQueue<Prompt>()
	// Which window shows the current prompt: every window's presenter asks it.
	private var claim = PromptWindowClaim()

	public init() {}

	// What shows now; nil between prompts and when nothing waits.
	public var current: Prompt? { queue.current }

	// Shows at once when nothing shows or waits; otherwise waits behind the rest. One that
	// `duplicate` matches against a prompt showing or waiting is dropped.
	public func ask(
		_ kind: Prompt.Kind, duplicate: (Prompt.Kind, Prompt.Kind) -> Bool = { _, _ in false }
	) {
		queue.enqueue(Prompt(kind: kind), duplicate: { duplicate($0.kind, $1.kind) })
	}

	// The prompt showing was answered or dismissed: the next waiting one shows once this one
	// has animated out. A stale id (already gone) changes nothing.
	public func dismiss(_ id: UUID) {
		guard queue.current?.id == id, queue.dismiss() else { return }
		Task { [weak self] in
			try? await Task.sleep(for: Self.representDelay)
			self?.queue.advance()
		}
	}

	// Whether `window` shows prompt `id` now (PromptWindowClaim's rule for its placement).
	public func shows(
		_ id: UUID?, in window: CommandWindow, isKey: Bool, anyWindowKey: Bool
	) -> Bool {
		guard let id, let prompt = queue.current, prompt.id == id else { return false }
		return claim.claims(
			id, placement: prompt.placement, for: window, isKey: isKey,
			anyWindowKey: anyWindowKey)
	}

	// `window` closed or its prompt was dismissed: what it held is free for the next taker.
	public func release(_ window: CommandWindow) {
		claim.release(window)
	}
}
