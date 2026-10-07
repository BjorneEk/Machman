//
//  EndProcessPrompt.swift
//  MachmanUI
//
//  The second, explicit question before Machman ends a VM's process (C9): what a Force Stop
//  asks when it can't reach a VM whose vmhost doesn't answer. One wording for the desktop
//  and the agent, one sentence each.
//

import Foundation
import AppKit
import MachmanAPI

public struct EndProcessPrompt: Equatable, Sendable {
	// The lab's answers-file key (LabAnswers).
	public let id: String
	public let title: String
	public let message: String
	public let confirm: String
	public let cancel: String

	public static func forVM(_ name: String) -> EndProcessPrompt {
		EndProcessPrompt(
			id: "agent.endProcess",
			title: "\u{201C}\(name)\u{201D} isn’t answering — end its process?",
			message: "Ending its Machman VM process stops the VM at once, like pulling its "
				+ "power cord.",
			confirm: "End Process", cancel: "Cancel")
	}

	// The agent's quit after "Force Stop All & Quit" left VMs whose vmhosts didn't answer:
	// end them, or quit and leave them running, as the quit prompt's first choice does.
	public static func forQuit(leaving names: [String]) -> EndProcessPrompt {
		guard names.count != 1 else {
			let one = forVM(names[0])
			return EndProcessPrompt(
				id: "agent.endProcessOnQuit", title: one.title, message: one.message,
				confirm: one.confirm, cancel: "Leave Running")
		}
		return EndProcessPrompt(
			id: "agent.endProcessOnQuit",
			title: "\(names.count) VMs aren’t answering — end their processes?",
			message: "Ending their Machman VM processes stops them at once, like pulling their "
				+ "power cords.",
			confirm: "End Process", cancel: "Leave Running")
	}

	public var labPrompt: LabPrompt {
		LabPrompt(id: id, message: title, info: message, buttons: [confirm, cancel], cancelIndex: 1)
	}

	// The agent's alert, in front (PromptAlert): true when the user chose to end the process.
	@MainActor
	public func runInFront() -> Bool {
		PromptAlert.run(labPrompt, destructiveIndex: 0) == 0
	}
}
