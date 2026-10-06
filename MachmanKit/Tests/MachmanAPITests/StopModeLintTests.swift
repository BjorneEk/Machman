//
//  StopModeLintTests.swift
//  MachmanAPITests
//
//  Every desktop stop names how it stops (Q8). VMListViewModel.stopVM defaulted its mode to
//  .force, the one that cuts a guest's power, and its only defaulting caller was the dead
//  toggleRun — so the next affordance written as stopVM(name) would have force stopped a
//  guest silently. Scanned: the desktop's view-model, view and app sources.
//

import Foundation
import Testing
import MachmanTestSupport

// L1: lint (repo files).
struct StopModeLintTests {
	private static let directories = [
		"MachmanKit/Sources/MachmanDesktopCore", "MachmanKit/Sources/MachmanDesktopUI",
		"MachmanDesktop",
	]

	@Test("Q8: no desktop stop falls back to a default mode")
	func everyStopNamesItsMode() throws {
		let defaulted = try NSRegularExpression(pattern: #"mode: StopMode = "#)
		let toggle = try NSRegularExpression(pattern: #"func toggleRun\("#)
		#expect(!RepoFiles.files(under: Self.directories, extension: "swift").isEmpty)
		let hits = RepoFiles.grep(defaulted, under: Self.directories, extension: "swift")
			+ RepoFiles.grep(toggle, under: Self.directories, extension: "swift")
		#expect(hits.isEmpty, "\(hits.map(\.description).joined(separator: "\n"))")
	}
}
