//
//  VMHostTestModeTests.swift
//  MachmanCoreTests
//
//  TB7: a test-suite vmhost never reaches the screen. It opens no VM window (no Dock icon,
//  activation or key capture), captures no preview (no Screen Recording prompt), and answers
//  every prompt from the lab's answers file by a stable id, logged, never shown. A test's own
//  seam still answers first; outside test mode the alert shows as before.
//

import Testing
import Foundation
import AppKit
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

@MainActor
struct VMHostTestModeTests {
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

	@Test("Q18: every vmhost prompt has its own lab id (TB7)")
	func everyVMHostPromptHasItsOwnLabID() {
		let prompts: [(HostPrompt, String, Int?)] = [
			(.closeWhileRunning("dev"), "vmhost.closeWhileRunning", 3),
			(.quitWhileRunning("dev", reason: .userQuit), "vmhost.quitWhileRunning", 2),
			(.quitWhileRunning("dev", reason: .logOut), "vmhost.sessionEndWhileRunning", 2),
			(.quitWhileRunning("dev", reason: .restart), "vmhost.sessionEndWhileRunning", 2),
			(.quitWhileRunning("dev", reason: .shutDown), "vmhost.sessionEndWhileRunning", 2),
			(.notShutDownYet("dev"), "vmhost.notShutDownYet", nil),
			(.shutDownRefused("dev"), "vmhost.shutDownRefused", 0),
			(.forceStopFailed("dev", reason: "It broke"), "vmhost.forceStopFailed", 0),
		]
		for (prompt, id, cancel) in prompts {
			#expect(prompt.id == id, "\(prompt.message): \(prompt.buttons.map(\.title))")
			#expect(prompt.labPrompt.id == id)
			#expect(prompt.labPrompt.cancelIndex == cancel, "\(id)")
			#expect(prompt.labPrompt.buttons == prompt.buttons.map(\.title))
			#expect(prompt.labPrompt.message == prompt.message)
		}
		// One id per factory (a log out, restart and shut down ask one question).
		#expect(Set(prompts.map(\.1)).count == 6)
	}

	// Q22: the id was read off a prompt's buttons and titles, so rewording one moved every
	// lab answer keyed on it. Each factory stores its id now.
	@Test("Q22: a vmhost prompt keeps its lab id whatever its wording")
	func aVMHostPromptKeepsItsLabIDWhateverItsWording() {
		let prompts: [HostPrompt] = [
			.closeWhileRunning("dev"), .quitWhileRunning("dev", reason: .userQuit),
			.quitWhileRunning("dev", reason: .logOut), .notShutDownYet("dev"),
			.shutDownRefused("dev"), .forceStopFailed("dev", reason: "It broke"),
		]
		for prompt in prompts {
			let reworded = HostPrompt(
				id: prompt.id, message: "Reworded", info: "Reworded too.",
				buttons: prompt.buttons.reversed().map {
					HostPrompt.Button(choice: $0.choice, title: $0.title + " Now")
				})
			#expect(reworded.labPrompt.id == prompt.labPrompt.id, "\(prompt.id)")
		}
	}

	@Test("Q18: a test-suite vmhost answers its prompts from the answers file (TB7)")
	func aTestSuiteVMHostAnswersFromTheFile() async throws {
		let presenter = WindowPresenter()
		presenter.lab = try Self.lab(answers: #"{"vmhost.closeWhileRunning": "Shut Down"}"#)
		#expect(presenter.present(.closeWhileRunning("dev")) == .shutDown)
		#expect(await presenter.ask(.closeWhileRunning("dev")) == .shutDown)

		presenter.lab = try Self.lab(answers: "{}")
		#expect(presenter.present(.closeWhileRunning("dev")) == .cancel)
		#expect(presenter.present(.quitWhileRunning("dev", reason: .logOut)) == .cancel)
		#expect(await presenter.ask(.notShutDownYet("dev")) == .keepWaiting)
		#expect(await presenter.ask(.shutDownRefused("dev")) == .cancel)

		// A test's own seam still answers first.
		presenter.answerPrompt = { _ in .forceStop }
		#expect(presenter.present(.closeWhileRunning("dev")) == .forceStop)
		#expect(await presenter.ask(.notShutDownYet("dev")) == .forceStop)
	}

	@Test("Q18: a vmhost shows an alert only outside test mode (TB7)")
	func aVMHostShowsAnAlertOnlyOutsideTestMode() throws {
		let lab = try Self.lab(answers: nil)
		#expect(WindowPresenter.route(hasSeam: true, lab: lab) == .seam)
		#expect(WindowPresenter.route(hasSeam: true, lab: nil) == .seam)
		#expect(WindowPresenter.route(hasSeam: false, lab: lab) == .lab)
		#expect(WindowPresenter.route(hasSeam: false, lab: nil) == .alert)
		for suite in ["com.gustaffranzen.Machman.dev", "com.gustaffranzen.Machman"] {
			let notLab = LabEnvironment(suiteID: suite, environment: [:], debugBuild: true)
			#expect(WindowPresenter.route(hasSeam: false, lab: notLab) == .alert)
		}
		// This run is a test suite: a presenter is in test mode unless told otherwise.
		#expect(WindowPresenter().lab == LabEnvironment.current)
		#expect(WindowPresenter().lab != nil)
	}

	@Test("Q18: a test-suite vmhost opens no window and captures no preview (TB7)")
	func aTestSuiteVMHostOpensNoWindowAndCapturesNoPreview() async throws {
		let lab = try Self.lab(answers: nil)
		#expect(!WindowPresenter.opensWindows(lab: lab))
		#expect(!WindowPresenter.capturesPreviews(lab: lab))
		#expect(WindowPresenter.opensWindows(lab: nil))
		#expect(WindowPresenter.capturesPreviews(lab: nil))
		let presenter = WindowPresenter()
		presenter.lab = lab
		var failures: [WindowPresenter.CaptureFailure] = []
		presenter.onCaptureFailed = { failures.append($0) }
		let image = await presenter.captureImage(name: "dev")
		#expect(image.size == NSSize(width: 300, height: 200))
		#expect(failures.isEmpty)
		#expect(presenter.window(for: "dev") == nil)
	}

	// Q23: a test-suite vmhost kept .accessory, so activation stayed possible, and the lab
	// could quit it only by an Apple Event (an Automation prompt). It runs prohibited now and
	// takes quits on a control socket beside its agent's; outside test mode neither changes.
	@Test("Q23: a test-suite vmhost runs prohibited and serves lab control beside its agent's")
	func aTestSuiteVMHostRunsProhibitedWithLabControl() throws {
		let token = String(TestEnvironment.suiteID.dropFirst(MachmanTestMode.suitePrefix.count))
		let control = ["MACHMAN_LAB_AGENT_CONTROL": "/tmp/mml.\(token)/scopes/01/agent.ctl"]
		let lab = try #require(LabEnvironment(
			suiteID: TestEnvironment.suiteID, environment: control, debugBuild: true))
		#expect(VMHostBootstrap.activationPolicy(lab: lab) == .prohibited)
		#expect(VMHostBootstrap.labControlPath(vm: "dev copy", lab: lab)
			== "/tmp/mml.\(token)/scopes/01/vm-\(MachmanPaths.shortHash("dev copy")).ctl")
		let noControl = try #require(LabEnvironment(
			suiteID: TestEnvironment.suiteID, environment: [:], debugBuild: true))
		#expect(VMHostBootstrap.labControlPath(vm: "dev", lab: noControl) == nil)
		#expect(VMHostBootstrap.activationPolicy(lab: nil) == .accessory)
		#expect(VMHostBootstrap.labControlPath(vm: "dev", lab: nil) == nil)
		for suite in ["com.gustaffranzen.Machman.dev", "com.gustaffranzen.Machman"] {
			let notLab = LabEnvironment(suiteID: suite, environment: control, debugBuild: true)
			#expect(VMHostBootstrap.activationPolicy(lab: notLab) == .accessory)
			#expect(VMHostBootstrap.labControlPath(vm: "dev", lab: notLab) == nil)
		}
	}
}
