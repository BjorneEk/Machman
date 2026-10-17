//
//  SSHInspectorTests.swift
//  MachmanDesktopUITests
//
//  The SSH inspectors read from the real views hosted offscreen: the Keys section stays away
//  until it has a row (N4).
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
}
