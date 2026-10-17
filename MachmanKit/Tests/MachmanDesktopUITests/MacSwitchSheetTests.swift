//
//  MacSwitchSheetTests.swift
//  MachmanDesktopUITests
//
//  D32 (K4): the switch to macOS asks where to install — a new disk, preselected, or one of
//  the VM's own disks, each by name — and says what a picked disk loses. A disk smaller than
//  a new one can be picked, with a warning (K15). A retry asks nothing.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopUI

@MainActor
struct MacSwitchSheetTests {
	@Test("D32: the switch sheet names every disk it can erase and warns for the picked one")
	func theSheetAsksWhereToInstall() async throws {
		let h = await UIHarness.make([
			Samples.linuxBeforeMacSwitch(), Samples.macOSFailedInstall(),
		])
		let warning = "macOS may not fit on a disk under 64 GB"
		let fresh = try await h.snapshot(MacSwitchSheet(viewModel: h.viewModel, vm: h.vm("Alpine")))
		let rows = fresh.findAll { $0.role == "AXRadioButton" }
		#expect(rows.map(\.text) == [
			"A new disk (64 GB)", "system (80 GB)", "data (8 GB), \(warning)",
			"ubuntu-24.04-arm64.img (20 GB), \(warning)",
		], "\(fresh.dump())")
		#expect(rows.map(\.isSelected) == [true, false, false, false])
		#expect(rows.map(\.help) == [nil, nil, warning, warning])
		#expect(rows.allSatisfy { $0.isEnabled }, "a small disk can be picked (K15)")
		#expect(!fresh.all.contains { $0.text?.hasPrefix("Installing erases") == true })

		let picked = try await h.snapshot(
			MacSwitchSheet(viewModel: h.viewModel, vm: h.vm("Alpine"), pick: "storage:data"))
		#expect(picked.find(role: "AXRadioButton", text: "data (8 GB), \(warning)")?.isSelected
			== true, "\(picked.dump())")
		let erases = "Installing erases \u{201C}data\u{201D} and can\u{2019}t be undone."
		#expect(picked.find(text: erases) != nil)
		#expect(picked.find(text: warning + ".") != nil)

		// A retry reuses its own disk without asking.
		let retry = try await h.snapshot(
			MacSwitchSheet(viewModel: h.viewModel, vm: h.vm("Sequoia")))
		#expect(!retry.all.contains { $0.role == "AXRadioGroup" }, "\(retry.dump())")
	}
}
