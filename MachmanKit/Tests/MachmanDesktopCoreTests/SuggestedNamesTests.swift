//
//  SuggestedNamesTests.swift
//  MachmanDesktopCoreTests
//
//  Q4: Duplicate's and Save as New VM's suggested names come from the one numbering rule
//  (UniqueName): the base while it is free, else the first free “<base> N”.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct SuggestedNamesTests {
	@Test func suggestedNamesNumberPastTakenVMs() async {
		let h = await DesktopHarness.make([
			Samples.linux("Debian"), Samples.linux("Debian copy"), Samples.linux("Debian saved"),
		])
		#expect(h.viewModel.defaultCopyName(for: "Debian") == "Debian copy 2")
		#expect(h.viewModel.defaultSafeSaveName(for: "Debian") == "Debian saved 2")
		#expect(h.viewModel.defaultCopyName(for: "Debian copy") == "Debian copy copy")
	}
}
