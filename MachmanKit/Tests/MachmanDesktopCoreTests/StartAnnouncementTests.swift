//
//  StartAnnouncementTests.swift
//  MachmanDesktopCoreTests
//
//  RR3-1: the daemon announces a spawned vmhost's run itself — stateChanged(running), then
//  listChanged — and the vmhost's own running state may still trail them. However they
//  interleave, a start is one "started" toast (O-6a toasted it twice).
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct StartAnnouncementTests {
	@Test func anAnnouncedStartToastsOnce() async {
		let h = await DesktopHarness.make()
		h.stub.vms["Alpine"]?.state = .running
		h.stub.emit(.stateChanged(vm: "Alpine", state: .running))
		h.stub.emit(.listChanged)
		h.stub.emit(.stateChanged(vm: "Alpine", state: .running))   // the vmhost's own, late

		// The store handles its events in order: once this reload lands, all of the above has.
		h.stub.vms["Debian"]?.cpuCount = 7
		h.stub.emit(.listChanged)
		#expect(await eventually { h.store.vms.first { $0.name == "Debian" }?.cpuCount == 7 })
		#expect(h.viewModel.toasts.filter { $0.message == "Alpine started" }.count == 1)
	}
}
