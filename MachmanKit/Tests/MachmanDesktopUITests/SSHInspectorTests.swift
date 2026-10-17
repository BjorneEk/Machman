//
//  SSHInspectorTests.swift
//  MachmanDesktopUITests
//
//  The SSH inspectors read from the real views hosted offscreen: the Keys section stays away
//  until it has a row (N4), and a session's emptied name says why it can't be used, then
//  tidies back to the name it keeps (H64).
//

import SwiftUI
import Testing
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

// L1: desktop views hosted offscreen, read through in-process accessibility.
@MainActor
struct SSHInspectorTests {
	private func ssh(_ vm: VMInfo) async throws -> AXSnapshot {
		let h = await UIHarness.make([vm])
		return try await h.snapshot(
			SSHInspector(viewModel: h.viewModel, vm: h.vm(vm.name)), width: 320, height: 820)
	}

	@Test("N4: the SSH inspector shows no Keys section before there is a key")
	func noKeysSectionWithoutAKey() async throws {
		let bare = try await ssh(Samples.linux("Debian"))
		#expect(bare.find(text: "Keys") == nil, "\(bare.dump())")
		#expect(bare.find(text: "Reset SSH State\u{2026}") != nil)
		let sshfs = try await ssh(Samples.linuxSSHFS(.approved))
		#expect(sshfs.find(text: "Keys") != nil, "\(sshfs.dump())")
	}

	@Test("H64: an emptied session name says why, and Return tidies it back")
	func anEmptySessionNameSaysWhy() async throws {
		let h = await UIHarness.make(select: "Debian")
		let ref = SSHSessionRef(title: "Session 1")
		h.terminals.renameSSHSession(vm: "Debian", ref: ref, to: "Build")
		let field: (AXSnapshot) -> AXSnapshot? = { tree in
			tree.all.first { $0.role == "AXTextField" }
		}
		let (typed, submitted) = try await OffscreenHost.withHost(
			SSHSessionInspector(
				viewModel: h.viewModel, sessions: h.terminals, profiles: h.profiles,
				vm: h.vm("Debian"), ref: ref),
			width: 320, height: 600
		) { hosted in
			let frame = try #require(field(hosted.snapshot())?.frame)
			#expect(await FieldTyping.type("  ", intoFieldAt: frame, in: hosted))
			let typed = hosted.snapshot()
			// The problem line moved the field: Return goes where it is now.
			let moved = try #require(field(typed)?.frame)
			#expect(await FieldTyping.submit(fieldAt: moved, in: hosted))
			return (typed, hosted.snapshot())
		}
		#expect(typed.find(text: "A session needs a name") != nil, "\(typed.dump())")
		#expect(field(submitted)?.value == "Build", "\(submitted.dump())")
		#expect(submitted.find(text: "A session needs a name") == nil)
		#expect(h.terminals.sshSessionName(vm: "Debian", ref: ref) == "Build")
	}
}
