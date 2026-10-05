//
//  EndProcessPrompt.swift
//  MachmanUI
//
//  The second, explicit question before Machman ends a VM's process (C9): what a Force Stop
//  asks when it can't reach a VM whose vmhost doesn't answer. One wording for the desktop
//  and the agent, one sentence each.
//

import Foundation

public struct EndProcessPrompt: Equatable, Sendable {
	public let title: String
	public let message: String
	public let confirm: String
	public let cancel: String

	public static func forVM(_ name: String) -> EndProcessPrompt {
		EndProcessPrompt(
			title: "\u{201C}\(name)\u{201D} isn’t answering — end its process?",
			message: "Ending its Machman VM process stops the VM at once, like pulling its "
				+ "power cord.",
			confirm: "End Process", cancel: "Cancel")
	}
}
