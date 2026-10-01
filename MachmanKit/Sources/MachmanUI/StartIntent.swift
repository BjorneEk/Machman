//
//  StartIntent.swift
//  MachmanUI
//
//  The one start rule every client shares (decision 7): a plain Start follows the VM's start
//  policy — window mode AND safety — and a named item overrides only what it names. Start
//  Headless drops the window but keeps the policy's safety; Start Safe adds safety but keeps
//  the policy's window mode. The desktop's view model and the menu-bar agent both turn an
//  intent into StartOptions here, so no affordance can pick its own mix.
//

import Foundation
import MachmanAPI

public enum StartIntent: Sendable, Equatable {
	case plain
	case headless
	case safe
}

extension VMInfo {
	// nil policy = a pre-policy daemon: its defaults (window on, not safe). Never forced: a
	// MAC-conflict retry is its own, explicit, call.
	public func startOptions(_ intent: StartIntent = .plain) -> StartOptions {
		let policy = startPolicy ?? StartPolicy()
		switch intent {
		case .plain:
			return StartOptions(openWindow: policy.windowed, safe: policy.safe)
		case .headless:
			return StartOptions(openWindow: false, safe: policy.safe)
		case .safe:
			return StartOptions(openWindow: policy.windowed, safe: true)
		}
	}
}
