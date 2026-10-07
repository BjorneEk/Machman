//
//  NetworkAddressSourceTests.swift
//  MachmanDesktopUITests
//
//  Where the network inspector says the guest's address came from (E56): this Mac's DHCP
//  leases, the ARP table, or the guest's own report — read from the real inspector hosted
//  offscreen. What the agent's discovery finds is the engine's and the lab's (L1, L3).
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
struct NetworkAddressSourceTests {
	private func network(_ vm: VMInfo) async throws -> AXSnapshot {
		let h = await UIHarness.make([vm], select: vm.name)
		h.viewModel.select(name: vm.name)
		h.viewModel.treeSelection = [.device(.network)]
		return try await h.snapshot(
			InspectorView(
				viewModel: h.viewModel, sessions: h.terminals, profiles: h.profiles,
				vm: h.vm(vm.name)),
			width: 320, height: 820)
	}

	@Test("E56: the network inspector says an address the guest reported")
	func aReportedAddressReadsReported() async throws {
		let reported = try await network(Samples.reportedAddress())
		#expect(reported.find(text: "Reported by the guest.") != nil, "\(reported.dump())")
		#expect(reported.find(text: "Found in the ARP table.") == nil)
		let leased = try await network(Samples.linux("Debian", state: .running))
		#expect(leased.find(text: "Found in this Mac\u{2019}s DHCP leases.") != nil)
	}
}
