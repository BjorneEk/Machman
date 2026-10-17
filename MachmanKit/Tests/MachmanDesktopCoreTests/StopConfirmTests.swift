//
//  StopConfirmTests.swift
//  MachmanDesktopCoreTests
//
//  P26: ⌘. is the system cancel chord, and from a focused terminal it reached the Stop menu
//  and shut the VM down at once. The Stop menu's chords now ask first; only a confirmation
//  stops the VM.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
import MachmanUI
@testable import MachmanDesktopCore

@MainActor
struct StopConfirmTests {
	@Test func shutDownAsksFirst() async throws {
		let h = await DesktopHarness.make()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		h.viewModel.requestStop(debian, mode: .soft)
		#expect(h.viewModel.pendingStop?.vm == "Debian")
		#expect(h.viewModel.pendingStop?.mode == .soft)
		#expect(await h.settled())
		#expect(!h.stub.calls.contains("stop"))
		#expect(h.stub.vms["Debian"]?.state == .running)
	}

	@Test func confirmingShutsDownSoftly() async throws {
		let h = await DesktopHarness.make()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		h.viewModel.requestStop(debian, mode: .soft)
		let pending = try #require(h.viewModel.pendingStop)
		h.viewModel.confirmStop(pending)
		#expect(h.viewModel.pendingStop == nil)
		#expect(await eventually { h.stub.vms["Debian"]?.state == .stopped })
	}

	// C9 (E36): a Force Stop can't reach a VM whose vmhost doesn't answer. The desktop asks a
	// second, explicit question, and only its confirmation ends the process.
	@Test func aForceStopOfANotRespondingVMAsksAboutItsProcess() async throws {
		let h = await DesktopHarness.make(Samples.libraryWithStalledHost())
		h.viewModel.stopVM("Debian", mode: .force)
		#expect(h.viewModel.pendingEndProcess?.vm == "Debian")
		#expect(await h.settled())
		#expect(!h.stub.calls.contains("stop"))   // the daemon's bounded wait is skipped
		#expect(!h.stub.calls.contains("endProcess"))

		let pending = try #require(h.viewModel.pendingEndProcess)
		h.viewModel.isEndProcessPresented = false   // the alert's dismissal
		h.viewModel.endProcess(pending.vm)            // its End Process button
		#expect(await eventually { h.stub.calls.contains("endProcess") })
		#expect(h.viewModel.pendingEndProcess == nil)
	}

	// A host that wedged after the list last said so: the daemon's bounded force stop answers
	// timeout, and the same question follows instead of a failure alert.
	@Test func aTimedOutForceStopAsksAboutItsProcess() async throws {
		let h = await DesktopHarness.make()
		h.stub.fail("stop", with: MachmanError(
			code: .timeout, message: "Debian isn\u{2019}t answering, so it didn\u{2019}t stop"))
		h.viewModel.stopVM("Debian", mode: .force)
		#expect(await eventually { h.viewModel.pendingEndProcess?.vm == "Debian" })
		#expect(h.viewModel.presentedError == nil)
		#expect(!h.stub.calls.contains("endProcess"))
	}

	// A Shut Down that times out is no cue: the guest was asked, not the process.
	@Test func aTimedOutShutDownIsJustAFailure() async throws {
		let h = await DesktopHarness.make()
		h.stub.fail("stop", with: MachmanError(code: .timeout, message: "No answer"))
		h.viewModel.stopVM("Debian", mode: .soft)
		#expect(await eventually { h.viewModel.presentedError != nil })
		#expect(h.viewModel.pendingEndProcess == nil)
	}

	// Review F11: a safe start the user stopped while it prepared comes back canceled; no
	// "Starting … failed" alert follows the user's own action.
	@Test func aCanceledSafeStartSaysNothing() async throws {
		let h = await DesktopHarness.make()
		h.stub.fail("start", with: MachmanError(
			code: .cancelled, message: "The safe run was canceled"))
		h.viewModel.startVM("Debian", safe: true)
		#expect(await eventually {
			h.stub.calls.contains("start") && !h.viewModel.pendingStarts.contains("Debian")
		})
		#expect(await h.settled())
		#expect(h.viewModel.presentedError == nil)
	}

	// Review F12: a Machman Agent from before vm.process.end answers "method not found"; the
	// confirmed End Process falls back to the force stop that agent knows.
	@Test func anOlderAgentGetsAForceStopInstead() async throws {
		let h = await DesktopHarness.make()
		h.stub.fail("endProcess", with: MachmanError(
			code: .unsupported, message: "unknown method 'vm.process.end'"))
		h.viewModel.endProcess("Debian")
		#expect(await eventually { h.stub.vms["Debian"]?.state == .stopped })
		#expect(h.stub.calls.suffix(2) == ["endProcess", "stop"])
		#expect(h.viewModel.presentedError == nil)   // before: "Ending the process … failed"
	}

	@Test func theProcessQuestionIsOneSentenceEach() throws {
		let prompt = PendingEndProcess(vm: "Debian").prompt
		#expect(prompt.title
			== "\u{201C}Debian\u{201D} isn\u{2019}t answering \u{2014} end its process?")
		#expect(prompt.message == "Ending its Machman VM process stops the VM at once, like "
			+ "pulling its power cord.")
		#expect(prompt.confirm == "End Process")
		#expect(prompt.cancel == "Cancel")
		let sentenceEnd = try Regex(#"[.?!](\s|$)"#)
		#expect(prompt.message.matches(of: sentenceEnd).count == 1)
	}

	@Test func forceStopNamesItself() {
		let soft = PendingStop(vm: "Debian", mode: .soft)
		#expect(soft.title == "Shut down \u{201C}Debian\u{201D}?")
		#expect(soft.message == "Debian’s guest is asked to shut down.")
		#expect(soft.confirmLabel == "Shut Down")
		let force = PendingStop(vm: "Debian", mode: .force)
		#expect(force.title == "Force stop \u{201C}Debian\u{201D}?")
		#expect(force.message == "Debian stops at once, like pulling its power cord.")
		#expect(force.confirmLabel == "Force Stop")
	}
}
