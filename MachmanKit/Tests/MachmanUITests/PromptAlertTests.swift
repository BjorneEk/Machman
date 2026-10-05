//
//  PromptAlertTests.swift
//  MachmanUITests
//
//  TB9: every alert the menu-bar agent shows goes through PromptAlert, which under a test
//  suite logs and answers it from the lab's answers file by a stable id instead — without
//  touching NSApp, so these run headless with no alert, activation or Dock icon. Outside
//  test mode the alert shows, as before.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
import MachmanUI

@MainActor
struct PromptAlertTests {
	private static func lab(answers: String) throws -> LabEnvironment {
		let path = TestEnvironment.scratch + "answers-\(UUID().uuidString).json"
		try Data(answers.utf8).write(to: URL(fileURLWithPath: path))
		return try #require(LabEnvironment(
			suiteID: TestEnvironment.suiteID, environment: ["MACHMAN_LAB_ANSWERS": path],
			debugBuild: true))
	}

	@Test("Q18: the agent menu's questions carry lab ids and cancel buttons (TB9)")
	func theAgentMenusQuestionsCarryLabIDs() {
		let conflict = MenuBarFailure(
			vm: "Debian", action: .start(StartOptions()),
			error: MachmanError(code: .macConflict, message: "Alpine already uses it"))
		#expect(conflict.labPrompt == LabPrompt(
			id: "agent.macConflict", message: "MAC address conflict",
			info: "Alpine already uses it", buttons: ["Start Anyway", "Cancel"], cancelIndex: 1))
		let failed = MenuBarFailure(
			vm: "Debian", action: .stop(.soft),
			error: MachmanError(code: .invalidState, message: "Debian is installing"))
		#expect(failed.labPrompt == LabPrompt(
			id: "agent.actionFailed", message: "Couldn’t shut down \u{201C}Debian\u{201D}",
			info: "Debian is installing", buttons: ["OK"], cancelIndex: nil))

		let forVM = EndProcessPrompt.forVM("Debian")
		#expect(forVM.labPrompt == LabPrompt(
			id: "agent.endProcess", message: forVM.title, info: forVM.message,
			buttons: ["End Process", "Cancel"], cancelIndex: 1))
		for leaving in [["Debian"], ["Debian", "Alpine"]] {
			let forQuit = EndProcessPrompt.forQuit(leaving: leaving)
			#expect(forQuit.labPrompt == LabPrompt(
				id: "agent.endProcessOnQuit", message: forQuit.title, info: forQuit.message,
				buttons: ["End Process", "Leave Running"], cancelIndex: 1))
		}
	}

	@Test("Q18: PromptAlert answers from the answers file under a test suite (TB9)")
	func promptAlertAnswersFromTheFile() throws {
		let quit = EndProcessPrompt.forQuit(leaving: ["Debian"])
		let lab = try Self.lab(answers: #"{"agent.endProcessOnQuit": "End Process"}"#)
		for front in [PromptAlert.Front.activate, .lendDockIcon] {
			#expect(PromptAlert.run(quit.labPrompt, front: front, lab: lab) == 0)
			#expect(PromptAlert.run(
				EndProcessPrompt.forVM("Debian").labPrompt, front: front, destructiveIndex: 0,
				lab: lab) == 1)   // not listed: its cancel button
		}
		let none = try Self.lab(answers: "{}")
		let conflict = MenuBarFailure(
			vm: "Debian", action: .start(StartOptions()),
			error: MachmanError(code: .macConflict, message: "Alpine already uses it"))
		#expect(PromptAlert.run(conflict.labPrompt, front: .activate, lab: none) == 1)
	}

	@Test("Q18: PromptAlert shows an alert only outside test mode (TB9)")
	func promptAlertShowsAnAlertOnlyOutsideTestMode() throws {
		#expect(PromptAlert.route(lab: nil) == .alert)
		#expect(PromptAlert.route(lab: try Self.lab(answers: "{}")) == .lab)
		for suite in ["com.gustaffranzen.Machman.dev", "com.gustaffranzen.Machman"] {
			let lab = LabEnvironment(suiteID: suite, environment: [:], debugBuild: true)
			#expect(PromptAlert.route(lab: lab) == .alert)
		}
		// This run is a test suite: an alert the code forgets to route is still answered.
		#expect(PromptAlert.route(lab: .current) == .lab)
	}
}
