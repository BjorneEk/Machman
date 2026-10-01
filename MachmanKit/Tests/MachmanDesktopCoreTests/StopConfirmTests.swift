//
//  StopConfirmTests.swift
//  MachmanDesktopCoreTests
//
//  P26: ⌘. is the system cancel chord, and from a focused terminal it reached the Stop menu
//  and shut the VM down at once. The Stop menu's chords now ask first; only a confirmation
//  stops the VM.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct StopConfirmTests {
	@Test func shutDownAsksFirst() async throws {
		let h = await DesktopHarness.make()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		h.viewModel.requestStop(debian, mode: .soft)
		#expect(h.viewModel.pendingStop?.vm == "Debian")
		#expect(h.viewModel.pendingStop?.mode == .soft)
		try await Task.sleep(for: .milliseconds(50))
		#expect(!h.stub.calls.contains("stop"))
		#expect(h.stub.vms["Debian"]?.state == .running)
	}

	@Test func confirmingShutsDownSoftly() async throws {
		let h = await DesktopHarness.make()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		h.viewModel.requestStop(debian, mode: .soft)
		let pending = try #require(h.viewModel.pendingStop)
		h.viewModel.confirmStop(pending)
		#expect(h.viewModel.pendingStop == nil)
		#expect(await eventually { h.stub.vms["Debian"]?.state == .stopped })
	}

	@Test func forceStopNamesItself() {
		let soft = PendingStop(vm: "Debian", mode: .soft)
		#expect(soft.title == "Shut down \u{201C}Debian\u{201D}?")
		#expect(soft.message == "Debian's guest is asked to shut down.")
		#expect(soft.confirmLabel == "Shut Down")
		let force = PendingStop(vm: "Debian", mode: .force)
		#expect(force.title == "Force stop \u{201C}Debian\u{201D}?")
		#expect(force.message == "Debian stops at once, like pulling its power cord.")
		#expect(force.confirmLabel == "Force Stop")
	}
}
