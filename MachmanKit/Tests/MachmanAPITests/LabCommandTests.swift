//
//  LabCommandTests.swift
//  MachmanAPITests
//
//  TB11: the lab's control lines for a test-suite agent — ping, quit with a reason, and the
//  agent menu's items by VM — parse into commands, and anything else into the reason the
//  reply gives.
//

import Testing
import Foundation
import MachmanAPI

struct LabCommandTests {
	@Test("Q18: lab control lines parse into commands (TB11)")
	func labControlLinesParseIntoCommands() {
		let commands: [(String, LabCommand)] = [
			("ping", .ping),
			("ping\r", .ping),
			("quit", .quit(.userQuit)),
			("quit logOut", .quit(.logOut)),
			("quit restart", .quit(.restart)),
			("quit shutDown\r", .quit(.shutDown)),
			("menu start dev", .menu(.start, vm: "dev")),
			("menu startHeadless dev copy", .menu(.startHeadless, vm: "dev copy")),
			("menu forceStop  two  spaces ", .menu(.forceStop, vm: " two  spaces ")),
			("menu closeWindow Debian 13 (arm)", .menu(.closeWindow, vm: "Debian 13 (arm)")),
		]
		for (line, command) in commands {
			#expect(LabCommand.parse(line) == .success(command), "\(line.debugDescription)")
		}
		for action in LabMenuAction.allCases {
			#expect(LabCommand.parse("menu \(action.rawValue) vm")
				== .success(.menu(action, vm: "vm")))
		}
		let errors: [(String, String)] = [
			("", "empty command"),
			("bogus", "unknown command 'bogus'"),
			("PING", "unknown command 'PING'"),
			("ping now", "ping takes no arguments"),
			("quit soon", "no quit reason 'soon'"),
			("menu", "menu needs an action"),
			("menu launch dev", "no menu action 'launch'"),
			("menu start", "menu start needs a VM name"),
			("menu start ", "menu start needs a VM name"),
		]
		for (line, reason) in errors {
			#expect(LabCommand.parse(line) == .failure(LabCommandError(reason)),
				"\(line.debugDescription)")
		}
	}
}
