//
//  LabAnswersTests.swift
//  MachmanAPITests
//
//  TB2: under test mode a prompt is never shown — it is answered from the lab's answers file
//  by its stable id and logged as one line. The decision is a pure function of the file's
//  bytes; only answerIfTesting reads the file, and only under test mode.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport

@MainActor
struct LabAnswersTests {
	@MainActor
	private final class Flag {
		var isSet = false
	}

	private static let quit = LabPrompt(
		id: "agent.vmsStillRunning", message: "VMs are still running", info: "…",
		buttons: ["Quit, Leave VMs Running", "Shut Down All & Quit", "Force Stop All & Quit",
			"Cancel"],
		cancelIndex: 3)
	private static let failed = LabPrompt(
		id: "agent.actionFailed", message: "Couldn’t start “dev”", info: "It broke.",
		buttons: ["OK"], cancelIndex: nil)

	private static func json(_ text: String) -> Data { Data(text.utf8) }

	private static func lab(answers: String?) throws -> LabEnvironment {
		var environment: [String: String] = [:]
		if let answers {
			let path = TestEnvironment.scratch + "answers-\(UUID().uuidString).json"
			try Data(answers.utf8).write(to: URL(fileURLWithPath: path))
			environment["MACHMAN_LAB_ANSWERS"] = path
		}
		return try #require(LabEnvironment(
			suiteID: TestEnvironment.suiteID, environment: environment, debugBuild: true))
	}

	@Test("Q18: a listed button answers its prompt (TB2)")
	func aListedButtonAnswers() {
		let decision = LabAnswers.decide(
			Self.quit, answers: Self.json(#"{"agent.vmsStillRunning": "Shut Down All & Quit"}"#))
		#expect(decision == .init(index: 1, holdSeconds: 0, listed: true, problem: nil))
	}

	@Test("Q18: an unlisted prompt takes its cancel button, else its default (TB2)")
	func anUnlistedPromptTakesItsCancelElseItsDefault() {
		let other = Self.json(#"{"agent.replaceOlder": "Replace"}"#)
		for answers in [nil, Data(), other] {
			#expect(LabAnswers.decide(Self.quit, answers: answers)
				== .init(index: 3, holdSeconds: 0, listed: false, problem: nil))
			#expect(LabAnswers.decide(Self.failed, answers: answers).index == 0)
		}
	}

	@Test("Q18: an unknown button or an unreadable file falls back and says why (TB2)")
	func anUnknownButtonOrAnUnreadableFileFallsBack() {
		let unknown = LabAnswers.decide(
			Self.quit, answers: Self.json(#"{"agent.vmsStillRunning": "Quit"}"#))
		#expect(unknown.index == 3)
		#expect(unknown.problem == "no button \u{201C}Quit\u{201D}")
		for bad in [
			"not json", #"["Cancel"]"#, #"{"agent.vmsStillRunning": 3}"#,
			#"{"agent.vmsStillRunning": {"holdSeconds": 2}}"#,
			#"{"agent.vmsStillRunning": {"button": "Cancel", "holdSeconds": "2"}}"#,
			#"{"agent.vmsStillRunning": {"button": "Cancel", "holdSeconds": true}}"#,
			#"{"agent.vmsStillRunning": {"button": "Cancel", "holdSeconds": 601}}"#,
			#"{"agent.vmsStillRunning": {"button": "Cancel", "holdSeconds": -1}}"#,
		] {
			let decision = LabAnswers.decide(Self.quit, answers: Self.json(bad))
			#expect(decision.index == 3, "\(bad)")
			#expect(decision.problem == "unreadable answers file", "\(bad)")
		}
	}

	@Test("Q18: the object form holds the answer (TB2)")
	func theObjectFormHoldsTheAnswer() {
		let held = LabAnswers.decide(Self.quit, answers: Self.json(
			#"{"agent.vmsStillRunning": {"button": "Cancel", "holdSeconds": 1.5}}"#))
		#expect(held == .init(index: 3, holdSeconds: 1.5, listed: true, problem: nil))
		let unheld = LabAnswers.decide(Self.quit, answers: Self.json(
			#"{"agent.vmsStillRunning": {"button": "Force Stop All & Quit"}}"#))
		#expect(unheld == .init(index: 2, holdSeconds: 0, listed: true, problem: nil))
		let whole = LabAnswers.decide(Self.quit, answers: Self.json(
			#"{"agent.vmsStillRunning": {"button": "Cancel", "holdSeconds": 1}}"#))
		#expect(whole.holdSeconds == 1)
	}

	@Test("Q18: every answer logs one line with its id, message and button (TB2)")
	func everyAnswerLogsOneLine() {
		let listed = LabAnswers.Decision(index: 0, holdSeconds: 0, listed: true, problem: nil)
		#expect(LabAnswers.logLine(Self.quit, listed)
			== "test prompt agent.vmsStillRunning: \"VMs are still running\" \u{2192} "
			+ "Quit, Leave VMs Running")
		let unlisted = LabAnswers.Decision(index: 3, holdSeconds: 0, listed: false, problem: nil)
		#expect(LabAnswers.logLine(Self.quit, unlisted)
			== "test prompt agent.vmsStillRunning: \"VMs are still running\" \u{2192} Cancel "
			+ "(not listed)")
		let held = LabAnswers.Decision(index: 3, holdSeconds: 2, listed: true, problem: nil)
		#expect(LabAnswers.logLine(Self.quit, held)
			== "test prompt agent.vmsStillRunning: \"VMs are still running\" \u{2192} Cancel "
			+ "(held 2 s)")
		let half = LabAnswers.Decision(index: 0, holdSeconds: 0.5, listed: true, problem: nil)
		#expect(LabAnswers.logLine(Self.failed, half)
			== "test prompt agent.actionFailed: \"Couldn’t start “dev”\" \u{2192} OK (held 0.5 s)")
	}

	@Test("Q18: outside test mode no prompt is answered (TB2)")
	func outsideTestModeNoPromptIsAnswered() {
		#expect(LabAnswers.answerIfTesting(Self.quit, lab: nil) == nil)
		for suite in ["com.gustaffranzen.Machman.dev", "com.gustaffranzen.Machman"] {
			let lab = LabEnvironment(
				suiteID: suite, environment: ["MACHMAN_LAB_ANSWERS": "/tmp/x.json"],
				debugBuild: true)
			#expect(lab == nil)
			#expect(LabAnswers.answerIfTesting(Self.quit, lab: lab) == nil)
		}
	}

	@Test("Q18: under test mode the answers file is read at each prompt (TB2)")
	func underTestModeTheFileIsReadAtEachPrompt() throws {
		let lab = try Self.lab(answers: #"{"agent.vmsStillRunning": "Shut Down All & Quit"}"#)
		#expect(LabAnswers.answerIfTesting(Self.quit, lab: lab) == 1)
		try Data(#"{"agent.vmsStillRunning": "Quit, Leave VMs Running"}"#.utf8)
			.write(to: URL(fileURLWithPath: try #require(lab.answersPath)))
		#expect(LabAnswers.answerIfTesting(Self.quit, lab: lab) == 0)
		// No answers file at all: every prompt takes its cancel button.
		#expect(LabAnswers.answerIfTesting(Self.quit, lab: try Self.lab(answers: nil)) == 3)
	}

	// A held answer stands in for an alert a person leaves up: like NSAlert.runModal started
	// from a run-loop callout, it must let every other main-actor job run meanwhile (the
	// agent's and a vmhost's servers keep answering under it).
	@Test("Q18: a held answer keeps the main queue draining (TB2)")
	func aHeldAnswerKeepsTheMainQueueDraining() async throws {
		let lab = try Self.lab(
			answers: #"{"agent.vmsStillRunning": {"button": "Cancel", "holdSeconds": 2}}"#)
		let (answer, ranMeanwhile) = await MainRunLoopCallout.run { () -> (Int?, Bool) in
			let other = Flag()
			Task { @MainActor in other.isSet = true }   // e.g. the server handling a request
			let answer = LabAnswers.answerIfTesting(Self.quit, lab: lab)
			return (answer, other.isSet)
		}
		#expect(answer == 3)
		#expect(ranMeanwhile)
	}
}
