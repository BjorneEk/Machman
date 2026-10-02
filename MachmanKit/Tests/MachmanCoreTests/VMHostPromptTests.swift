//
//  VMHostPromptTests.swift
//  MachmanTests
//
//  The vmhost's prompts as values (VMHostPrompts.swift) and the ⌘Q decision behind them,
//  on a TestVMHost whose answerPrompt seam stands in for the modal alert. A log out's
//  prompt is VMHostQuitTests'.
//

import Testing
import Foundation
import AppKit
import MachmanAPI
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
		#expect(followUp.message == "alpha hasn’t shut down yet")
		#expect(followUp.info == "The guest hasn’t responded to the shutdown request.")
		#expect(titles(followUp) == ["Keep Waiting", "Force Stop"])
		#expect(followUp.buttons.map(\.choice) == [.keepWaiting, .forceStop])
	}

	@Test func theQuitPromptOffersBothStopsAndCancel() {
		let quit = HostPrompt.quitWhileRunning("alpha", reason: .userQuit)
		#expect(quit.message == "alpha is running")
		#expect(quit.info
			== "Quitting stops the VM: ask the guest to shut down, or stop it now.")
		#expect(titles(quit) == ["Shut Down", "Force Stop", "Cancel"])
		#expect(quit.buttons.map(\.choice) == [.shutDown, .forceStop, .cancel])
		#expect(quit.escapeButton == nil)   // AppKit gives "Cancel" Esc itself
	}

	// V5: a refused or failed stop is said at once; Cancel is the refusal's safe default.
	@Test func theStopFailurePromptsSayWhatHappened() {
		let refused = HostPrompt.shutDownRefused("alpha")
		#expect(refused.message == "alpha can’t be asked to shut down")
		#expect(refused.info
			== "The guest can’t take a shutdown request right now — force stop it instead?")
		#expect(titles(refused) == ["Cancel", "Force Stop"])
		#expect(refused.buttons.map(\.choice) == [.cancel, .forceStop])

		let failed = HostPrompt.forceStopFailed("alpha", reason: "The VM refused to stop.")
		#expect(failed.message == "alpha couldn’t be stopped")
		#expect(failed.info == "The VM refused to stop.")
		#expect(titles(failed) == ["OK"])
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
	) async {
		let host = TestVMHost {
			$0 == .quitWhileRunning("alpha", reason: .userQuit) ? answer : .keepWaiting
		}
		#expect(host.delegate.terminateReply(for: .userQuit) == .terminateCancel)
		#expect(host.prompts.first == .quitWhileRunning("alpha", reason: .userQuit))
		#expect(await eventually { host.stops == stops })
	}

	@Test func anIdleHostQuitsAtOnce() {
		let host = TestVMHost(running: false) { _ in .shutDown }
		#expect(host.delegate.terminateReply(for: .userQuit) == .terminateNow)
		#expect(host.prompts.isEmpty)
		#expect(host.stops.isEmpty)
	}
}
