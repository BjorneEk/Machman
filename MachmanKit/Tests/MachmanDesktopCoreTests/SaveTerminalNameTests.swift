//
//  SaveTerminalNameTests.swift
//  MachmanDesktopCoreTests
//
//  H63: File ▸ Save Terminal… offered "terminal.log" for every VM and port. It now suggests
//  "<vm> <tab>.log" — the port as the tree names it, an SSH tab by its session's current
//  name — from the tab the saved terminal serves; a slash or colon in a name becomes "-".
//  The sheet itself is MachmanDesktopUI's (SaveTranscriptTests; manual row for the sheet).
//

import Foundation
import Testing
import UniformTypeIdentifiers
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct SaveTerminalNameTests {
	private let console = SerialPortRef(kind: .console, index: 0)
	private let session = SSHSessionRef(title: "Session 1")

	@Test("H63: Save Terminal suggests “<vm> <port>.log”, an SSH tab its session's name")
	func theSaveNamesTheTab() async throws {
		let h = await DesktopHarness.make()
		h.terminals.ensureController(
			vm: "Debian", ref: console, socketPath: "/var/empty/machman-sample/c0.sock",
			profile: h.profiles.defaultProfile)
		h.terminals.ensureSSHController(
			vm: "Debian", ref: session, arguments: ["debian.machman"],
			profile: h.profiles.defaultProfile)
		_ = await eventually {
			h.terminals.controller(for: .terminal(console), vm: "Debian") != nil
				&& h.terminals.controller(for: .ssh(session), vm: "Debian") != nil
		}
		let serial = try #require(h.terminals.controller(vm: "Debian", ref: console))
		let ssh = try #require(h.terminals.sshController(vm: "Debian", ref: session))
		#expect(h.terminals.tab(of: serial)?.vm == "Debian")
		#expect(h.terminals.tab(of: serial)?.tab == .terminal(console))

		let request = h.viewModel.transcriptSaveRequest(for: serial)
		#expect(request.name == "Debian hvc0.log")
		#expect(request.contentTypes == [.plainText])
		h.terminals.renameSSHSession(vm: "Debian", ref: session, to: "build/box: 2")
		#expect(h.viewModel.transcriptSaveRequest(for: ssh).name == "Debian build-box- 2.log")
		// A terminal no tab holds any more keeps the old neutral name.
		let stray = FakeTerminalController(profile: h.profiles.defaultProfile)
		#expect(h.viewModel.transcriptSaveRequest(for: stray).name == "terminal.log")
	}
}
