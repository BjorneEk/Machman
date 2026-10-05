//
//  LabCommands.swift
//  MachmanAPI
//
//  The lab's control protocol for a test-suite agent (MACHMAN_LAB_AGENT_CONTROL): what a lab
//  test needs to trigger inside the agent that no socket request reaches — a quit with a
//  chosen reason (the log out, restart and shut down rows) and the agent menu's own items.
//  One line in, one line out:
//
//    ping                                  → ok
//    quit [userQuit|logOut|restart|shutDown]  → ok, then the agent quits for that reason
//    menu <action> <vm name>               → ok | disabled | error no VM named <vm> | …
//    anything else                         → error <why>
//
//  The VM name is the rest of the line, spaces kept. Served only under test mode.
//

import Foundation

public enum LabQuitReason: String, CaseIterable, Sendable {
	case userQuit
	case logOut
	case restart
	case shutDown
}

// The agent menu's items, by the lab's names.
public enum LabMenuAction: String, CaseIterable, Sendable {
	case start
	case startHeadless
	case startSafe
	case shutDown
	case forceStop
	case openWindow
	case closeWindow
}

public struct LabCommandError: Error, Equatable, Sendable {
	public let reason: String

	public init(_ reason: String) {
		self.reason = reason
	}
}

public enum LabCommand: Equatable, Sendable {
	case ping
	case quit(LabQuitReason)
	case menu(LabMenuAction, vm: String)

	public static func parse(_ line: String) -> Result<LabCommand, LabCommandError> {
		var text = Substring(line)
		if text.hasSuffix("\r") { text = text.dropLast() }
		let (verb, rest) = split(text)
		switch verb {
		case "ping":
			guard rest == nil else { return .failure(LabCommandError("ping takes no arguments")) }
			return .success(.ping)
		case "quit":
			guard let rest else { return .success(.quit(.userQuit)) }
			guard let reason = LabQuitReason(rawValue: String(rest)) else {
				return .failure(LabCommandError("no quit reason '\(rest)'"))
			}
			return .success(.quit(reason))
		case "menu":
			guard let rest else { return .failure(LabCommandError("menu needs an action")) }
			let (name, vm) = split(rest)
			guard let action = LabMenuAction(rawValue: String(name)) else {
				return .failure(LabCommandError("no menu action '\(name)'"))
			}
			guard let vm, !vm.isEmpty else {
				return .failure(LabCommandError("menu \(action.rawValue) needs a VM name"))
			}
			return .success(.menu(action, vm: String(vm)))
		case "":
			return .failure(LabCommandError("empty command"))
		default:
			return .failure(LabCommandError("unknown command '\(verb)'"))
		}
	}

	// The first word and, after one space, the rest of the line (nil when there is none).
	private static func split(_ text: Substring) -> (Substring, Substring?) {
		guard let space = text.firstIndex(of: " ") else { return (text, nil) }
		return (text[..<space], text[text.index(after: space)...])
	}
}
