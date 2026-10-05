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
	// The user quit the agent: its prompt offers what happens to the VMs. Work the agent runs
	// itself rides along — any way of quitting stops it, so it is asked about too (F10).
	case ask([SessionHolder])
	// The user quit the agent while it runs work of its own and no VM runs (E47): quitting
	// would stop the work, so it asks first.
	case askAboutWork([SessionHolder])

	public static func decide(
		reason: VMHostQuitReason, runningVMs: Int, holders: [SessionHolder]
	) -> AgentQuitDecision {
		if reason == .userQuit {
			if runningVMs > 0 { return .ask(holders.filter(\.isAgentWork)) }
			return holders.isEmpty ? .quit : .askAboutWork(holders)
		}
		guard !holders.isEmpty else { return .quit }
		let unexplained = holders.filter { !$0.promptsItself }
		return unexplained.isEmpty ? .cancelQuietly : .cancelAndExplain(unexplained)
	}
}

// One VM that holds a log out, restart or shut down while the agent runs, and whether its own
// vmhost says so: only a vmhost running its VM, and answering, cancels in front (V1). Work
// the agent runs itself — a copy, an import into a stopped VM, a macOS install — holds it
// too, since it would die with the agent (C13).
public struct SessionHolder: Equatable, Sendable {
	public let vm: String
	// What it does, after its name: "is still starting", "is being copied".
	public let activity: String
	public let promptsItself: Bool
	// Work the agent runs itself, not a VM that runs: quitting the agent stops it.
	public let isAgentWork: Bool

	public init(vm: String, activity: String, promptsItself: Bool, isAgentWork: Bool = false) {
		self.vm = vm
		self.activity = activity
		self.promptsItself = promptsItself
		self.isAgentWork = isAgentWork
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

	// The user quit the agent while it runs work of its own (E47). The first button, the
	// default, keeps it.
	public static func quitDuringWork(_ holders: [SessionHolder]) -> AgentPrompt {
		let one = holders.count == 1
		return AgentPrompt(
			message: (one
				? "\(holders[0].vm) \(holders[0].activity)" : "\(holders.count) VMs are busy")
				+ " — quit anyway?",
			info: "Quitting Machman Agent now stops \(one ? "it" : "them").",
			buttons: ["Cancel", "Quit Anyway"])
	}

	// The older agent refused to be replaced while it runs work of its own (E45); `reason` is
	// its refusal, which names the work and has no period of its own.
	public static func replaceRefused(reason: String) -> AgentPrompt {
		AgentPrompt(
			message: "The older Machman Agent can’t be replaced yet", info: reason + ".",
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
