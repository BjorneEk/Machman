//
//  AgentPrompts.swift
//  MachmanCore
//
//  The menu-bar agent's quit decision as a value, so it is testable without AppKit's quit
//  handling. Each running VM's own vmhost already cancels a log out, restart or shut down,
//  and says what to do in its own window (V1). An agent that asked as well, or quit, would
//  only add a second alert or leave the VMs unmanaged (V7, the user's answer U1), so it
//  steps aside quietly then: it cancels its own quit and keeps running.
//

import Foundation

public enum AgentQuitDecision: Equatable, Sendable {
	case quit            // nothing runs: stop serving and quit
	case cancelQuietly   // the session is ending under running VMs: stay, say nothing
	case ask             // the user quit the agent: its prompt offers what happens to the VMs

	public static func decide(reason: VMHostQuitReason, runningVMs: Int) -> AgentQuitDecision {
		guard runningVMs > 0 else { return .quit }
		return reason == .userQuit ? .ask : .cancelQuietly
	}
}
