//
//  PromptCenterTests.swift
//  MachmanDesktopCoreTests
//
//  PR25 (Q31, T31): the view model kept nine prompt states in three shapes. Errors queued
//  and showed in the key window (H40), but a start's MAC-conflict question and a force stop's
//  End Process question were one slot each, shown only by the main window: a second one
//  replaced the first, and one asked from a torn window landed behind it, or nowhere while
//  the main window was closed. Every prompt is one queue now, PromptCenter, and the window
//  key when one arrives shows it (K8).
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// L1: view model on StubMachman.
@MainActor
struct PromptCenterTests {
	private static let macConflict = MachmanError(code: .macConflict, message: "MAC in use")

	@Test("Q31: two MAC-conflict refusals in a row ask two questions, in order")
	func twoMacConflictsAskTwice() async {
		let h = await DesktopHarness.make([Samples.linux("Alpine"), Samples.linux("Fedora")])
		h.stub.fail("start", with: Self.macConflict)
		h.viewModel.startVM("Alpine")
		#expect(await eventually { !h.viewModel.isStartPending("Alpine") })
		h.stub.fail("start", with: Self.macConflict)
		h.viewModel.startVM("Fedora")
		#expect(await eventually { !h.viewModel.isStartPending("Fedora") })
		#expect(await h.settled())
		#expect(h.viewModel.pendingForceStart?.name == "Alpine")
		h.viewModel.isForceStartPresented = false
		#expect(await eventually { h.viewModel.pendingForceStart?.name == "Fedora" })
	}

	@Test("Q31: two not-responding force stops ask two End Process questions")
	func twoForceStopsAskTwice() async {
		let h = await DesktopHarness.make([
			Samples.notResponding("Debian"), Samples.notResponding("Fedora"),
		])
		h.viewModel.stopVM("Debian", mode: .force)
		h.viewModel.stopVM("Fedora", mode: .force)
		#expect(h.viewModel.pendingEndProcess?.vm == "Debian")
		h.viewModel.isEndProcessPresented = false
		#expect(await eventually { h.viewModel.pendingEndProcess?.vm == "Fedora" })
	}

	// K8: like an error (C22), a start's MAC question and a force stop's End Process question
	// show in the window that was key when they arrived — a torn window's Start or a menu
	// item with a torn window in front — and never in a second window.
	@Test("T31: the MAC and End Process questions show in the window key when they arrive")
	func questionsShowInTheKeyWindow() async throws {
		let h = await DesktopHarness.make([
			Samples.linux("Alpine"), Samples.notResponding("Debian"),
		])
		let torn = CommandWindow.torn(TornTab(vm: "Alpine", tab: .config))
		h.stub.fail("start", with: Self.macConflict)
		h.viewModel.startVM("Alpine")
		#expect(await eventually { h.viewModel.pendingForceStart != nil })
		let question = try #require(h.viewModel.prompts.current)
		let prompts = h.viewModel.prompts
		#expect(!prompts.shows(question.id, in: .main, isKey: false, anyWindowKey: true))
		#expect(prompts.shows(question.id, in: torn, isKey: true, anyWindowKey: true))
		#expect(!prompts.shows(question.id, in: .main, isKey: true, anyWindowKey: true))

		// Answered there; the End Process question asked next waits for a window to be key,
		// and the main window takes it while Machman is in the background.
		prompts.release(torn)
		h.viewModel.isForceStartPresented = false
		h.viewModel.stopVM("Debian", mode: .force)
		#expect(await eventually { h.viewModel.pendingEndProcess?.vm == "Debian" })
		let next = try #require(prompts.current)
		#expect(!prompts.shows(next.id, in: torn, isKey: false, anyWindowKey: false))
		#expect(prompts.shows(next.id, in: .main, isKey: false, anyWindowKey: false))
	}
}
