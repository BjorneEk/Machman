//
//  PromptWindowClaimTests.swift
//  MachmanDesktopCoreTests
//
//  H40 (C22): an error alert shows in the window that was key when it arrived, once. A
//  refused change in a torn window's inspector popped up in the main window, or nowhere until
//  the main window reopened. The alerts themselves don't host offscreen; this is the rule
//  every window's prompt presenter asks (PromptWindowClaim, formerly the error's own).
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
@testable import MachmanDesktopCore

struct PromptWindowClaimTests {
	static let torn = CommandWindow.torn(TornTab(vm: "Debian", tab: .config))

	@Test("H40: an error shows once, in the window key when it arrived")
	func anErrorShowsOnceWhereItArrived() {
		var claim = PromptWindowClaim()
		func ask(_ error: UUID?, _ window: CommandWindow, key: Bool, anyKey: Bool) -> Bool {
			claim.claims(error, for: window, isKey: key, anyWindowKey: anyKey)
		}
		let first = UUID()
		// The torn window is key: it takes the error, and the main window can't have it too.
		#expect(!ask(first, .main, key: false, anyKey: true))
		#expect(ask(first, Self.torn, key: true, anyKey: true))
		#expect(!ask(first, .main, key: true, anyKey: true))
		// Its alert's sheet takes key: the window keeps what it shows.
		#expect(ask(first, Self.torn, key: false, anyKey: true))

		// The torn window closes with the alert up: the next window to be key shows it.
		claim.release(Self.torn)
		#expect(!ask(first, .main, key: false, anyKey: true))
		#expect(ask(first, .main, key: true, anyKey: true))
		claim.release(Self.torn)   // not its holder: changes nothing
		#expect(claim.window == .main)

		// Machman in the background: the main window takes a new error, a torn one doesn't.
		let second = UUID()
		#expect(!ask(second, Self.torn, key: false, anyKey: false))
		#expect(ask(second, .main, key: false, anyKey: false))
		// No error, nothing to show.
		#expect(!ask(nil, .main, key: true, anyKey: true))
	}
	// A question asked in one window (a tab close from a torn window) shows only there, key
	// or not, and never in the main window.
	@Test("Q31: a prompt placed in one window shows only in that window")
	func aPromptForOneWindowShowsOnlyThere() {
		var claim = PromptWindowClaim()
		let question = UUID()
		let placement = PromptPlacement.window(Self.torn)
		let inMain = claim.claims(
			question, placement: placement, for: .main, isKey: true, anyWindowKey: true)
		let inTorn = claim.claims(
			question, placement: placement, for: Self.torn, isKey: false, anyWindowKey: true)
		#expect(!inMain)
		#expect(inTorn)
		#expect(claim.window == Self.torn)
	}
}

