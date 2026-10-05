//
//  SaveTranscriptTests.swift
//  MachmanDesktopUITests
//
//  R3W1-8 (P11): File ▸ Save Terminal writes off the main thread, and a write that fails —
//  a read-only file in place, a volume that went away — comes back as the save's alert
//  instead of vanishing with its detached task. The save panel is AppKit; the write behind
//  it runs here, with no panel made.
//

import Foundation
import Testing
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

// L1: view model (UIHarness, nothing hosted).
@MainActor
struct SaveTranscriptTests {
	@Test("R3W1-8: saving a transcript over a read-only file shows the save alert")
	func aReadOnlyFileShowsTheSaveAlert() async throws {
		let h = await UIHarness.make()
		let dir = TestEnvironment.scratchURL.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let url = dir.appendingPathComponent("terminal.log")
		try Data("old".utf8).write(to: url)
		let manager = FileManager.default
		try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
		defer { try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

		h.viewModel.writeTerminalTranscript(Data("new".utf8), to: url)
		#expect(await eventually { h.viewModel.presentedError != nil })
		#expect(h.viewModel.presentedError?.title == "Saving the terminal log failed")
		#expect(try Data(contentsOf: url) == Data("old".utf8))
	}

	@Test("Q18: a transcript written to a writable place lands without an alert")
	func aWritableFileTakesTheTranscript() async throws {
		let h = await UIHarness.make()
		let url = TestEnvironment.scratchURL.appendingPathComponent("\(UUID()).log")
		h.viewModel.writeTerminalTranscript(Data("transcript".utf8), to: url)
		#expect(await eventually {
			(try? Data(contentsOf: url)) == Data("transcript".utf8)
		})
		#expect(h.viewModel.presentedError == nil)
	}
}
