//
//  VMHostPromptTests.swift
//  MachmanTests
//
//  The vmhost's prompts as values (VMHostPrompts.swift) and the quit decision behind them:
//  the presenter's answerPrompt seam stands in for the modal alert. The delegate's server is
//  never started (MachmanServer.init does not bind), so nothing listens.
//

import Testing
import Foundation
import AppKit
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

@MainActor
struct VMHostPromptTests {
	private func titles(_ prompt: HostPrompt) -> [String] {
		prompt.buttons.map(\.title)
	}

	@Test func theCloseAndFollowUpPromptsKeepTheirWording() {
		let close = HostPrompt.closeWhileRunning("alpha")
		#expect(close.message == "alpha is running")
		#expect(close.info == "Close the window and leave the VM running, "
			+ "ask the guest to shut down, or stop it immediately?")
		#expect(titles(close) == ["Close Window", "Shut Down", "Force Stop", "Cancel"])
		#expect(close.buttons.map(\.choice) == [.closeWindow, .shutDown, .forceStop, .cancel])

		let followUp = HostPrompt.notShutDownYet("alpha")
		#expect(followUp.message == "alpha hasn't shut down yet")
		#expect(followUp.info == "The guest hasn't responded to the shutdown request.")
		#expect(titles(followUp) == ["Keep Waiting", "Force Stop"])
		#expect(followUp.buttons.map(\.choice) == [.keepWaiting, .forceStop])
	}

	@Test func theQuitPromptOffersBothStopsAndCancel() {
		let quit = HostPrompt.quitWhileRunning("alpha")
		#expect(quit.message == "alpha is running")
		#expect(titles(quit) == ["Shut Down", "Force Stop", "Cancel"])
		#expect(quit.buttons.map(\.choice) == [.shutDown, .forceStop, .cancel])
	}

	@Test func anAnswerMapsByButtonPosition() {
		let close = HostPrompt.closeWhileRunning("alpha")
		#expect((0..<4).map(close.choice(forButtonAt:))
			== [.closeWindow, .shutDown, .forceStop, .cancel])
		#expect(close.choice(forButtonAt: 4) == .cancel)    // an aborted modal
		#expect(close.choice(forButtonAt: -1) == .cancel)
	}

	// A VM's host can't quit and leave it running: whatever the answer, the quit is cancelled
	// and the chosen stop (if any) is asked for; the stopped VM's exit ends the process.
	@Test(arguments: [
		(HostChoice.shutDown, [StopMode.soft]),
		(.forceStop, [.force]),
		(.cancel, []),
	])
	func aRunningVMsQuitIsCancelledWhateverTheAnswer(
		answer: HostChoice, stops: [StopMode]
	) {
		let host = QuitHost(running: true, answer: answer)
		#expect(host.delegate.terminateReply() == .terminateCancel)
		#expect(host.prompts == [.quitWhileRunning("alpha")])
		#expect(host.stops == stops)
	}

	@Test func anIdleHostQuitsAtOnce() {
		let host = QuitHost(running: false, answer: .shutDown)
		#expect(host.delegate.terminateReply() == .terminateNow)
		#expect(host.prompts.isEmpty)
		#expect(host.stops.isEmpty)
	}
}

// A vmhost's delegate over a presenter whose prompts and stops are recorded.
@MainActor
final class QuitHost {
	let presenter = WindowPresenter()
	let delegate: VMHostAppDelegate
	private(set) var prompts: [HostPrompt] = []
	private(set) var stops: [StopMode] = []

	init(running: Bool, answer: HostChoice) {
		delegate = VMHostAppDelegate(
			vmName: { "alpha" }, presenter: presenter,
			server: MachmanServer(
				api: StubMachman(),
				socketPath: TestEnvironment.scratch + "quit-\(UUID().uuidString).sock",
				daemonVersion: "test"))
		presenter.isRunning = { _ in running }
		presenter.stopHandler = { [unowned self] _, mode in stops.append(mode) }
		presenter.answerPrompt = { [unowned self] prompt in
			prompts.append(prompt)
			return answer
		}
	}
}
