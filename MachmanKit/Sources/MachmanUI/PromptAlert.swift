//
//  PromptAlert.swift
//  MachmanUI
//
//  The one way the menu-bar agent shows an alert: every question it asks (AgentPrompt, the
//  menu's failures, EndProcessPrompt) comes through here as a LabPrompt. Outside test mode it
//  is today's alert, brought to the front one way for all of them (PromptFront, V13). Under a
//  test suite it is logged and answered from the lab's answers file (LabAnswers) without
//  touching NSApp at all: no alert, no activation, no Dock icon.
//

import AppKit
import MachmanAPI

@MainActor
public enum PromptAlert {
	public enum Route: Equatable, Sendable {
		case lab
		case alert
	}

	public nonisolated static func route(lab: LabEnvironment?) -> Route {
		lab == nil ? .alert : .lab
	}

	// How every agent alert comes to the front (V13), the vmhost's rule: an LSUIElement app's
	// alert can otherwise sit behind every window with no Dock icon to find it by.
	public nonisolated static func frontSteps(
		policy: NSApplication.ActivationPolicy
	) -> [PromptFront.Step] {
		PromptFront.steps(ownsPolicy: true, hasDockIcon: policy == .regular)
	}

	// The chosen button's index.
	public static func run(
		_ prompt: LabPrompt, style: NSAlert.Style = .warning,
		destructiveIndex: Int? = nil, lab: LabEnvironment? = .current
	) -> Int {
		if route(lab: lab) == .lab, let answer = LabAnswers.answerIfTesting(prompt, lab: lab) {
			return answer
		}
		let steps = frontSteps(policy: NSApp.activationPolicy())
		for step in steps {
			switch step {
			case .lendDockIcon: NSApp.setActivationPolicy(.regular)
			case .activate: NSApp.activate(ignoringOtherApps: true)
			case .requestAttention: NSApp.requestUserAttention(.criticalRequest)
			}
		}
		defer {
			let lent = steps.contains(.lendDockIcon)
			if PromptFront.returnsToAccessory(lent: lent, windowsOpen: false) {
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
