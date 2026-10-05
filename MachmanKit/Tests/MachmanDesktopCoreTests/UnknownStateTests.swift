//
//  UnknownStateTests.swift
//  MachmanDesktopCoreTests
//
//  P37: the daemon lists a VM as unknown while Machman Agent hasn't reached its vmhost,
//  precisely so that no client offers a second Start — yet the desktop grouped unknown with
//  stopped: Start everywhere, the Dock's "Start X", and every click refused by the agent.
//  Unknown is busy now (VMBusyRule), whether the vmhost is being reached or never answered.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
import MachmanUI
@testable import MachmanDesktopCore

@MainActor
struct UnknownStateTests {
	@Test func anUnknownVMCannotStart() async throws {
		let libraries = [
			Samples.libraryWithUnreachedHost(), Samples.libraryWithNeverAnsweredHost(),
		]
		for library in libraries {
			let h = await DesktopHarness.make(library)
			let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
			#expect(debian.state == .unknown)
			#expect(!h.viewModel.canStart(debian))
			// Refused before it is sent: a start would set the pending mark at once.
			h.viewModel.startPolicyDriven(debian)
			h.viewModel.startPolicyDriven(debian, .safe)
			#expect(!h.viewModel.isStartPending("Debian"))
		}
	}
}
