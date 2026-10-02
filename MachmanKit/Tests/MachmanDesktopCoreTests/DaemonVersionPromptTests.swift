//
//  DaemonVersionPromptTests.swift
//  MachmanDesktopCoreTests
//
//  X7, W4: the desktop's too-old alerts ran two and three sentences and called the agent
//  "daemon". Each says it in one sentence now, as Machman Agent.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanDesktopCore

struct DaemonVersionPromptTests {
	@Test func anEmbeddedAgentIsOfferedAsAReplacement() {
		let prompt = DaemonVersionPrompt.tooOld(
			running: "1.0.11", floor: "1.0.12", canReplace: true)
		#expect(prompt.title == "The running Machman Agent is too old")
		#expect(prompt.message == "It runs version 1.0.11 and this app needs 1.0.12 or newer "
			+ "\u{2014} replacing it keeps your VMs running.")
		#expect(prompt.buttons == ["Replace", "Not Now"])
	}

	@Test func withoutOneItSaysToReinstall() {
		let prompt = DaemonVersionPrompt.tooOld(
			running: "1.0.11", floor: "1.0.12", canReplace: false)
		#expect(prompt.title == "Machman Agent is too old")
		#expect(prompt.message == "Version 1.0.11 is running, but this app needs 1.0.12 or newer "
			+ "\u{2014} reinstall Machman to update it.")
		#expect(prompt.buttons == ["OK"])
	}

	@Test func eachMessageIsOneSentenceWithoutDaemon() throws {
		let sentenceEnd = try Regex(#"[.?!](\s|$)"#)
		for canReplace in [true, false] {
			let prompt = DaemonVersionPrompt.tooOld(
				running: "1.0.11", floor: "1.0.12", canReplace: canReplace)
			// Version numbers' dots are not sentence ends: only a dot before a space or the end.
			#expect(prompt.message.matches(of: sentenceEnd).count == 1, "\(prompt.message)")
			#expect(!prompt.message.lowercased().contains("daemon"))
			#expect(!prompt.title.lowercased().contains("daemon"))
		}
	}
}
