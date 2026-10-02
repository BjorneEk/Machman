//
//  MenuBarRules.swift
//  MachmanUI
//
//  The menu-bar agent's decisions, kept out of its app target so they test headlessly
//  (P23): what a failed menu action says, whether it offers Start Anyway (a MAC conflict,
//  as the desktop does), and whether Start is offered while a macOS install runs.
//

import Foundation
import MachmanAPI

// One VM action from the agent's menu.
public enum MenuBarAction: Sendable, Equatable {
	case start(StartOptions)
	case stop(StopMode)
	case openWindow
	case closeWindow
}

// What the agent's alert says about an action that failed.
public struct MenuBarFailure: Equatable, Sendable {
	public let vm: String
	public let title: String
	public let message: String
	// A MAC conflict on a plain start: the same start, forced, if the user says so.
	public let forceStart: StartOptions?

	public init(vm: String, action: MenuBarAction, error: Error) {
		self.vm = vm
		let quoted = "\u{201C}\(vm)\u{201D}"
		let conflict = (error as? MachmanError)?.code == .macConflict
		switch action {
		case .start(let options):
			if conflict && !options.force {
				title = "MAC address conflict"
				forceStart = StartOptions(
					openWindow: options.openWindow, force: true, safe: options.safe)
			} else {
				title = "Couldn't start \(quoted)"
				forceStart = nil
			}
		case .stop(let mode):
			title = mode == .force
				? "Couldn't force stop \(quoted)" : "Couldn't shut down \(quoted)"
			forceStart = nil
		case .openWindow:
			title = "Couldn't open \(vm)'s window"
			forceStart = nil
		case .closeWindow:
			title = "Couldn't close \(vm)'s window"
			forceStart = nil
		}
		// The desktop's rule: the daemon's own sentence, never NSError boilerplate.
		message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
	}
}

extension VMInfo {
	// A macOS install is under way, so Start must wait. A live phase (the agent's event
	// stream) wins; without one, the daemon's list says installing only while a live
	// install session runs.
	public func isInstallingMacOS(phase: InstallPhase.Kind?) -> Bool {
		if let phase {
			switch phase {
			case .resolving, .downloading, .installing: return true
			case .idle, .installed, .failed, .interrupted: return false
			}
		}
		return boot.macInstallState?.kind == .installing
	}
}
