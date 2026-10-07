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
import MachmanAPI

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
			// Only the agent's own work dies with it: a copy a vmhost runs goes on (V15).
			let work = holders.filter(\.isAgentWork)
			if runningVMs > 0 { return .ask(work) }
			return work.isEmpty ? .quit : .askAboutWork(work)
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
// an alert in front of other windows. Each has a stable id: under a test suite the lab answers
// it by that id instead (LabAnswers).
public struct AgentPrompt: Equatable, Sendable {
	public let id: String
	public let message: String
	public let info: String
	// The first is the default (Return).
	public let buttons: [String]
	// The button Esc presses; nil for a prompt with only an OK.
	public let cancelIndex: Int?

	public var labPrompt: LabPrompt {
		LabPrompt(id: id, message: message, info: info, buttons: buttons, cancelIndex: cancelIndex)
	}

	// The agent couldn't serve its socket; `reason` is the error's own sentence.
	public static func cannotStart(reason: String) -> AgentPrompt {
		AgentPrompt(
			id: "agent.cannotStart", message: "Machman Agent can’t start", info: reason,
			buttons: ["OK"], cancelIndex: nil)
	}

	// The user quit the agent while VMs run: what happens to them.
	public static let vmsStillRunning = AgentPrompt(
		id: "agent.vmsStillRunning", message: "VMs are still running",
		info: "Running VMs live in their own processes: you can quit and leave them running "
			+ "(the next Machman Agent re-adopts them), ask the guests to shut down "
			+ "(force-stopped after 30 seconds), or force stop everything now.",
		buttons: [
			"Quit, Leave VMs Running", "Shut Down All & Quit", "Force Stop All & Quit", "Cancel",
		],
		cancelIndex: 3)

	// The agent's own word on a canceled log out, restart or shut down (V10): what holds it
	// that no VM window will explain.
	public static func sessionEndHeld(
		reason: VMHostQuitReason, holders: [SessionHolder]
	) -> AgentPrompt {
		let one = holders.count == 1
		let (canceled, again) = reason.canceled
		return AgentPrompt(
			id: "agent.sessionEndHeld",
			message: one
				? "\(holders[0].vm) \(holders[0].activity)" : "\(holders.count) VMs are busy",
			info: "\(canceled): wait for \(one ? "it" : "them") or stop \(one ? "it" : "them") "
				+ "in Machman, then \(again).",
			buttons: ["OK"], cancelIndex: nil)
	}

	// The user quit the agent while it runs work of its own (E47). The first button, the
	// default, keeps it.
	public static func quitDuringWork(_ holders: [SessionHolder]) -> AgentPrompt {
		let one = holders.count == 1
		return AgentPrompt(
			id: "agent.quitDuringWork",
			message: (one
				? "\(holders[0].vm) \(holders[0].activity)" : "\(holders.count) VMs are busy")
				+ " — quit anyway?",
			info: "Quitting Machman Agent now stops \(one ? "it" : "them").",
			buttons: ["Cancel", "Quit Anyway"], cancelIndex: 0)
	}

	// The older agent refused to be replaced while it runs work of its own (E45); `reason` is
	// its refusal, which names the work and has no period of its own.
	public static func replaceRefused(reason: String) -> AgentPrompt {
		AgentPrompt(
			id: "agent.replaceRefused",
			message: "The older Machman Agent can’t be replaced yet", info: reason + ".",
			buttons: ["OK"], cancelIndex: nil)
	}

	// A newly launched agent that finds an older one serving: replace it, or leave it be.
	public static func replaceOlder(running: String, mine: String) -> AgentPrompt {
		AgentPrompt(
			id: "agent.replaceOlder",
			message: "An older Machman Agent is still running",
			info: "Replacing version \(running) with \(mine) keeps its VMs running.",
			buttons: ["Replace", "Cancel"], cancelIndex: 1)
	}
}
