//
//  PromptWindowClaim.swift
//  MachmanDesktopCore
//
//  Which window shows the prompt showing now (H40, C22, K8). PromptCenter presents prompts
//  one at a time; the main window and every torn window can show one, and this decides which:
//  for a prompt placed in the key window, the window that is key when it arrives, or the
//  first to become key while it waits — so a refusal or a question from a torn window shows
//  in that window and never in two; while no window is key (Machman in the background) the
//  main window takes it. A prompt placed in one window shows only there. The claim is keyed
//  by the prompt, so one made before a reconnect never matches the new view model's prompts.
//

import Foundation

public struct PromptWindowClaim: Equatable {
	public private(set) var prompt: UUID?
	public private(set) var window: CommandWindow?

	public init() {}

	// Whether `window` shows `prompt` now: it holds it already, or takes it — being key, or
	// being the main window while no window is, or being the one window the prompt is for.
	public mutating func claims(
		_ prompt: UUID?, placement: PromptPlacement = .keyWindow, for window: CommandWindow,
		isKey: Bool, anyWindowKey: Bool
	) -> Bool {
		guard let prompt else { return false }
		if self.prompt == prompt { return self.window == window }
		switch placement {
		case .keyWindow:
			guard isKey || (window == .main && !anyWindowKey) else { return false }
		case .window(let only):
			guard window == only else { return false }
		}
		self.prompt = prompt
		self.window = window
		return true
	}

	// `window` closed or its prompt was dismissed: what it held is free for the next taker.
	public mutating func release(_ window: CommandWindow) {
		guard self.window == window else { return }
		prompt = nil
		self.window = nil
	}
}
