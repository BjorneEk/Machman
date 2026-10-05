//
//  AgentPrompts.swift
//  MachmanCore
//
//  The menu-bar agent's quit decision as a value, so it is testable without AppKit's quit
//  handling. Each running VM's own vmhost already cancels a log out, restart or shut down,
//  and says what to do in its own window (V1). An agent that asked as well, or quit, would
//  only add a second alert or leave the VMs unmanaged (V7, the user's answer U1), so it
//  steps aside quietly then: it cancels its own quit and keeps running. What no vmhost will
//  explain — a start in flight, a vmhost that doesn't answer — the agent says itself (V10).
//

import Foundation

public enum AgentQuitDecision: Equatable, Sendable {
	case quit            // nothing runs: stop serving and quit
	case cancelQuietly   // the session is ending under running VMs: stay, say nothing
	// …and some of what holds it has no window of its own to say so: a start still in flight,
	// a vmhost that doesn't answer (V10). The agent cancels, and says what in its own alert.
	case cancelAndExplain([SessionHolder])
	case ask             // the user quit the agent: its prompt offers what happens to the VMs

	public static func decide(
		reason: VMHostQuitReason, runningVMs: Int, holders: [SessionHolder]
	) -> AgentQuitDecision {
		guard reason != .userQuit else { return runningVMs > 0 ? .ask : .quit }
		guard !holders.isEmpty else { return .quit }
		let unexplained = holders.filter { !$0.promptsItself }
		return unexplained.isEmpty ? .cancelQuietly : .cancelAndExplain(unexplained)
	}
}

// One VM that holds a log out, restart or shut down while the agent runs it, and whether its
// own vmhost says so: only a vmhost running its VM, and answering, cancels in front (V1).
public struct SessionHolder: Equatable, Sendable {
	public let vm: String
	// What it does, after its name: "is still starting", "is not responding".
	public let activity: String
	public let promptsItself: Bool

	public init(vm: String, activity: String, promptsItself: Bool) {
		self.vm = vm
		self.activity = activity
		self.promptsItself = promptsItself
	}
}

// The agent's questions as values (decision 16: one sentence each); the agent turns one into
// an alert in front of other windows.
public struct AgentPrompt: Equatable, Sendable {
	public let message: String
	public let info: String
	// The first is the default (Return).
	public let buttons: [String]

	// The agent's own word on a canceled log out, restart or shut down (V10): what holds it
	// that no VM window will explain.
	public static func sessionEndHeld(
		reason: VMHostQuitReason, holders: [SessionHolder]
	) -> AgentPrompt {
		let one = holders.count == 1
		let canceled: String
		let again: String
		switch reason {
		case .logOut, .userQuit:
			(canceled, again) = ("Log out was canceled", "log out again")
		case .restart:
			(canceled, again) = ("Restart was canceled", "restart again")
		case .shutDown:
			(canceled, again) = ("Shut down was canceled", "shut down your Mac again")
		}
		return AgentPrompt(
			message: one
				? "\(holders[0].vm) \(holders[0].activity)" : "\(holders.count) VMs are busy",
			info: "\(canceled): wait for \(one ? "it" : "them") or stop \(one ? "it" : "them") "
				+ "in Machman, then \(again).",
			buttons: ["OK"])
	}

	// A newly launched agent that finds an older one serving: replace it, or leave it be.
	public static func replaceOlder(running: String, mine: String) -> AgentPrompt {
		AgentPrompt(
			message: "An older Machman Agent is still running",
			info: "Replacing version \(running) with \(mine) keeps its VMs running.",
			buttons: ["Replace", "Cancel"])
	}
}
