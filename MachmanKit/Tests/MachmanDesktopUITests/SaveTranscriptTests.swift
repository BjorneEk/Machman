//
//  SaveTranscriptTests.swift
//  MachmanDesktopUITests
//
//  R3W1-8 (P11): File ▸ Save Terminal writes off the main thread, and a write that fails —
//  a read-only file in place, a volume that went away — comes back as the save's alert
//  instead of vanishing with its detached task. The save panel is AppKit; the write behind
//  it runs here, with no panel made. H63: the save asks through the SavePanels seam (a sheet
//  in the app, never the app-modal runModal) with the request the view model names.
//

import Foundation
import Testing
import MachmanAPI
import MachmanUI
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

	@Test("H63: Save Terminal asks through the panel seam and writes where it answers")
	func theSaveAsksThePanelSeam() async throws {
		let h = await UIHarness.make()
		let url = TestEnvironment.scratchURL.appendingPathComponent("\(UUID()).log")
		var asked: [SavePanelRequest] = []
		let panels = SavePanels { request, answer in
			asked.append(request)
			answer(url)
		}
		h.viewModel.saveTerminalTranscript(of: Transcript(), panels: panels)
		#expect(asked == [.anyTranscript], "a terminal no tab holds keeps the neutral name")
		#expect(await eventually {
			(try? Data(contentsOf: url)) == Transcript.text
		})
		#expect(h.viewModel.presentedError == nil)
		// Cancel writes nothing.
		var cancelled = 0
		h.viewModel.saveTerminalTranscript(
			of: Transcript(), panels: SavePanels { _, answer in
				cancelled += 1
				answer(nil)
			})
		#expect(cancelled == 1)
	}

	// A terminal with a transcript and nothing behind it.
	@MainActor
	private final class Transcript: TerminalController {
		static let text = Data("login: root\n".utf8)
		let connected = false
		let startupSignature = TerminalProfile.oneDarkDefault.startupSignature
		func connect(path: String) {}
		func connect(stream: TerminalByteStream) {}
		func disconnect() {}
		func applyLive(_ profile: TerminalProfile) {}
		func note(_ text: String) {}
		func transcript() -> Data { Self.text }
	}
}
