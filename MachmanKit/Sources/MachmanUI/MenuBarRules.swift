//
//  MenuBarRules.swift
//  MachmanUI
//
//  The menu-bar agent's decisions, kept out of its app target so they test headlessly
//  (P23): what a failed menu action says, whether it offers Start Anyway (a MAC conflict,
//  as the desktop does), and which of a VM's Start and stop items are enabled (V11).
//

import Foundation
import MachmanAPI

// One VM action from the agent's menu.
public enum MenuBarAction: Sendable, Equatable {
	case start(StartOptions)
	case stop(StopMode)
	case openWindow
	case closeWindow
	// Ends the process of a VM's vmhost that doesn't answer, once confirmed (C9).
	case endProcess
}

// What the agent's alert says about an action that failed.
public struct MenuBarFailure: Equatable, Sendable {
	public let vm: String
	public let title: String
	public let message: String
	// A MAC conflict on a plain start: the same start, forced, if the user says so.
	public let forceStart: StartOptions?
	// A Force Stop the vmhost didn't answer in time (timeout): not a failure to report, but
	// the cue to ask about ending its process (C9).
	public let offersEndProcess: Bool
	// The user canceled it — a Stop while a safe start prepared: nothing to report (F11).
	public let isCanceled: Bool

	public init(vm: String, action: MenuBarAction, error: Error) {
		self.vm = vm
		let quoted = "\u{201C}\(vm)\u{201D}"
		let conflict = (error as? MachmanError)?.code == .macConflict
		offersEndProcess = action == .stop(.force) && (error as? MachmanError)?.code == .timeout
		isCanceled = (error as? MachmanError)?.code == .cancelled
		switch action {
		case .start(let options):
			if conflict && !options.force {
				title = "MAC address conflict"
				forceStart = StartOptions(
					openWindow: options.openWindow, force: true, safe: options.safe)
			} else {
				title = "Couldn’t start \(quoted)"
				forceStart = nil
			}
		case .stop(let mode):
			title = mode == .force
				? "Couldn’t force stop \(quoted)" : "Couldn’t shut down \(quoted)"
			forceStart = nil
		case .openWindow:
			title = "Couldn’t open \(vm)’s window"
			forceStart = nil
		case .closeWindow:
			title = "Couldn’t close \(vm)’s window"
			forceStart = nil
		case .endProcess:
			title = "Couldn’t end the process of \(quoted)"
			forceStart = nil
		}
		// The desktop's rule (MachmanError.userMessage): the daemon's own sentence, never a
		// struct dump or NSError boilerplate.
		message = MachmanError.userMessage(for: error)
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

	// The agent's Start items (V11): the desktop's rule — never while the VM may be running,
	// its state unknown included (VMBusyRule) — and never during a macOS install.
	public func menuBarCanStart(phase: InstallPhase.Kind?) -> Bool {
		!mayBeRunning && !isInstallingMacOS(phase: phase)
	}

	// Shut Down and Force Stop: whenever the VM may be running. A VM whose state the agent
	// can't see yet counts as running when the agent quits, so its menu can stop it too.
	public var menuBarCanStop: Bool {
		mayBeRunning
	}
}
