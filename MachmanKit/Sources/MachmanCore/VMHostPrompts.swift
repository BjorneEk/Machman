//
//  VMHostPrompts.swift
//  MachmanCore
//
//  The vmhost's questions to the user, as values: the close prompt, the quit prompt and the
//  shutdown follow-up. WindowPresenter.present shows one as an alert and answers with the
//  chosen button's meaning; tests answer it instead, so every flow behind a prompt runs
//  without a window or a modal loop. Also here: why the vmhost is asked to quit, and when a
//  prompt lends a windowless host a Dock icon.
//

import Foundation
import AppKit

// What a prompt's button means.
enum HostChoice: Equatable {
	case closeWindow
	case shutDown
	case forceStop
	case keepWaiting
	case cancel
}

struct HostPrompt: Equatable {
	struct Button: Equatable {
		let choice: HostChoice
		let title: String
	}

	let message: String
	let info: String
	// The first is the default (Return).
	let buttons: [Button]

	// The alert's answer by button position; anything else (an aborted modal) cancels.
	func choice(forButtonAt index: Int) -> HostChoice {
		buttons.indices.contains(index) ? buttons[index].choice : .cancel
	}

	// The button Esc presses where AppKit wouldn't pick it (it does for "Cancel"): a cancel
	// with its own title, never the default, which keeps Return.
	var escapeButton: Int? {
		buttons.indices.dropFirst().first {
			buttons[$0].choice == .cancel && buttons[$0].title != "Cancel"
		}
	}

	// The VM window's close button while its VM runs.
	static func closeWhileRunning(_ name: String) -> HostPrompt {
		HostPrompt(
			message: "\(name) is running",
			info: "Close the window and leave the VM running, "
				+ "ask the guest to shut down, or stop it immediately?",
			buttons: [
				Button(choice: .closeWindow, title: "Close Window"),
				Button(choice: .shutDown, title: "Shut Down"),
				Button(choice: .forceStop, title: "Force Stop"),
				Button(choice: .cancel, title: "Cancel"),
			])
	}

	// Quitting the vmhost while its VM runs: the VM dies with the process, so no "leave it
	// running" option. A log out, restart or shut down is already cancelled when this shows
	// (decision 6), so that prompt says what to do instead, and "Shut Down VM" can't be read
	// as shutting down the Mac.
	static func quitWhileRunning(_ name: String, reason: VMHostQuitReason) -> HostPrompt {
		let retry: String
		switch reason {
		case .userQuit:
			return HostPrompt(
				message: "\(name) is running",
				info: "Quitting stops the VM: ask the guest to shut down, or stop it now.",
				buttons: [
					Button(choice: .shutDown, title: "Shut Down"),
					Button(choice: .forceStop, title: "Force Stop"),
					Button(choice: .cancel, title: "Cancel"),
				])
		case .logOut:
			retry = "Log out was canceled: shut the VM down, then log out again."
		case .restart:
			retry = "Restart was canceled: shut the VM down, then restart again."
		case .shutDown:
			retry = "Shut down was canceled: shut the VM down, then shut down your Mac again."
		}
		return HostPrompt(
			message: "\(name) is still running",
			info: retry,
			buttons: [
				Button(choice: .shutDown, title: "Shut Down VM"),
				Button(choice: .forceStop, title: "Force Stop VM"),
				Button(choice: .cancel, title: "Keep Running"),
			])
	}

	// A shutdown request the guest hasn't acted on within the grace period.
	static func notShutDownYet(_ name: String) -> HostPrompt {
		HostPrompt(
			message: "\(name) hasn’t shut down yet",
			info: "The guest hasn’t responded to the shutdown request.",
			buttons: [
				Button(choice: .keepWaiting, title: "Keep Waiting"),
				Button(choice: .forceStop, title: "Force Stop"),
			])
	}

	// The guest can't take a shutdown request (still starting, paused). Cancel is the
	// default: a force stop loses unsaved work in the guest.
	static func shutDownRefused(_ name: String) -> HostPrompt {
		HostPrompt(
			message: "\(name) can’t be asked to shut down",
			info: "The guest can’t take a shutdown request right now — force stop it instead?",
			buttons: [
				Button(choice: .cancel, title: "Cancel"),
				Button(choice: .forceStop, title: "Force Stop"),
			])
	}

	// reason: the engine's own sentence.
	static func forceStopFailed(_ name: String, reason: String) -> HostPrompt {
		HostPrompt(
			message: "\(name) couldn’t be stopped",
			info: reason,
			buttons: [Button(choice: .cancel, title: "OK")])
	}
}

// Why the vmhost (or the agent, AgentQuitDecision) is asked to quit: the quit Apple event's
// kAEQuitReason, which loginwindow sets for a log out, restart or shut down. ⌘Q and the
// Dock's Quit carry none.
public enum VMHostQuitReason: Equatable, Sendable {
	case userQuit
	case logOut
	case restart
	case shutDown

	init(appleEventCode code: OSType?) {
		switch code {
		case OSType(kAELogOut), OSType(kAEReallyLogOut):
			self = .logOut
		case OSType(kAEShowRestartDialog), OSType(kAERestart):
			self = .restart
		case OSType(kAEShowShutdownDialog), OSType(kAEShutDown):
			self = .shutDown
		default:
			self = .userQuit
		}
	}

	// Read while AppKit handles the quit event, i.e. inside applicationShouldTerminate.
	@MainActor
	public static func current() -> VMHostQuitReason {
		guard let event = NSAppleEventManager.shared().currentAppleEvent,
			event.eventID == AEEventID(kAEQuitApplication) else {
			return .userQuit
		}
		let keyword = AEKeyword(kAEQuitReason)
		let reason = event.attributeDescriptor(forKeyword: keyword)
			?? event.paramDescriptor(forKeyword: keyword)
		let code = reason.map { $0.typeCodeValue != 0 ? $0.typeCodeValue : $0.enumCodeValue }
		return VMHostQuitReason(appleEventCode: code)
	}
}

// Every vmhost prompt comes to the front: it answers the user's own stop or quit, and an
// app-modal alert also blocks the VM window. A windowless (accessory) host has no Dock icon
// to bounce or ⌘-Tab to, so it turns regular while the prompt shows — never the daemon's
// presenter, which doesn't manage the menu-bar agent's policy.
enum PromptActivation {
	static func lendsDockIcon(
		managesPolicy: Bool, current: NSApplication.ActivationPolicy
	) -> Bool {
		managesPolicy && current != .regular
	}

	// A window opened meanwhile keeps the app regular, as openWindow set it.
	static func returnsToAccessory(lent: Bool, windowsOpen: Bool) -> Bool {
		lent && !windowsOpen
	}
}
