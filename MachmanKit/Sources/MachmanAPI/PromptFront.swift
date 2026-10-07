//
//  PromptFront.swift
//  MachmanAPI
//
//  How a prompt of a windowless Machman process comes to the front (V13): the menu-bar
//  agent's (PromptAlert, MachmanUI) and a vmhost's (WindowPresenter, MachmanCore) follow this
//  one rule. Activation is cooperative since macOS 14 and can be declined, so the Dock icon
//  also asks for attention; a process without one is lent one while the prompt shows, so the
//  alert can be found again behind other windows. Steps only — each side performs them on
//  NSApp.
//

import Foundation

public enum PromptFront {
	public enum Step: Equatable, Sendable {
		case lendDockIcon       // a regular activation policy while the prompt shows
		case activate
		case requestAttention   // a critical request: the Dock icon bounces until activated
	}

	// `ownsPolicy`: the process sets its own activation policy (a vmhost, the agent) — the
	// daemon's in-process presenter doesn't. `hasDockIcon`: it is a regular app already.
	public static func steps(ownsPolicy: Bool, hasDockIcon: Bool) -> [Step] {
		(ownsPolicy && !hasDockIcon ? [.lendDockIcon] : []) + [.activate, .requestAttention]
	}

	// After the prompt: a lent Dock icon goes back, unless a window opened meanwhile keeps
	// the app regular.
	public static func returnsToAccessory(lent: Bool, windowsOpen: Bool) -> Bool {
		lent && !windowsOpen
	}
}
