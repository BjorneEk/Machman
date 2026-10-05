//
//  PromptAlert.swift
//  MachmanUI
//
//  The one way the menu-bar agent shows an alert: every question it asks (AgentPrompt, the
//  menu's failures, EndProcessPrompt) comes through here as a LabPrompt. Outside test mode it
//  is today's alert, brought to the front the way its caller asks. Under a test suite it is
//  logged and answered from the lab's answers file (LabAnswers) without touching NSApp at
//  all: no alert, no activation, no Dock icon.
//

import AppKit
import MachmanAPI

@MainActor
public enum PromptAlert {
	// How an alert comes to the front: an LSUIElement app's alert can otherwise sit behind
	// every window.
	public enum Front: Sendable {
		case activate
		// …and a Dock icon while it shows, so it can be found again.
		case lendDockIcon
	}

	public enum Route: Equatable, Sendable {
		case lab
		case alert
	}

	public nonisolated static func route(lab: LabEnvironment?) -> Route {
		lab == nil ? .alert : .lab
	}

	// The chosen button's index.
	public static func run(
		_ prompt: LabPrompt, front: Front, style: NSAlert.Style = .warning,
		destructiveIndex: Int? = nil, lab: LabEnvironment? = .current
	) -> Int {
		if route(lab: lab) == .lab, let answer = LabAnswers.answerIfTesting(prompt, lab: lab) {
			return answer
		}
		if front == .lendDockIcon {
			NSApp.setActivationPolicy(.regular)
		}
		NSApp.activate(ignoringOtherApps: true)
		defer {
			if front == .lendDockIcon {
				NSApp.setActivationPolicy(.accessory)
			}
		}
		let alert = NSAlert()
		alert.messageText = prompt.message
		alert.informativeText = prompt.info
		alert.alertStyle = style
		for (index, title) in prompt.buttons.enumerated() {
			alert.addButton(withTitle: title).hasDestructiveAction = index == destructiveIndex
		}
		return alert.runModal().rawValue
			- NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
	}
}

// The agent menu's failure alert as the lab answers it: a MAC conflict offers Start Anyway.
extension MenuBarFailure {
	public var labPrompt: LabPrompt {
		forceStart == nil
			? LabPrompt(
				id: "agent.actionFailed", message: title, info: message, buttons: ["OK"],
				cancelIndex: nil)
			: LabPrompt(
				id: "agent.macConflict", message: title, info: message,
				buttons: ["Start Anyway", "Cancel"], cancelIndex: 1)
	}
}
