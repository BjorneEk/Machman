//
//  VMHostPrompts.swift
//  MachmanCore
//
//  The vmhost's questions to the user, as values: the close prompt, the quit prompt and the
//  shutdown follow-up. WindowPresenter.present shows one as an alert and answers with the
//  chosen button's meaning; tests answer it instead, so every flow behind a prompt runs
//  without a window or a modal loop.
//

import Foundation

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
	// running" option.
	static func quitWhileRunning(_ name: String) -> HostPrompt {
		HostPrompt(
			message: "\(name) is running",
			info: "Quitting stops the VM. Ask the guest to shut down, "
				+ "stop it immediately, or cancel?",
			buttons: [
				Button(choice: .shutDown, title: "Shut Down"),
				Button(choice: .forceStop, title: "Force Stop"),
				Button(choice: .cancel, title: "Cancel"),
			])
	}

	// A shutdown request the guest hasn't acted on within the grace period.
	static func notShutDownYet(_ name: String) -> HostPrompt {
		HostPrompt(
			message: "\(name) hasn't shut down yet",
			info: "The guest hasn't responded to the shutdown request.",
			buttons: [
				Button(choice: .keepWaiting, title: "Keep Waiting"),
				Button(choice: .forceStop, title: "Force Stop"),
			])
	}
}
