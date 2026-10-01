//
//  InterruptedActionsTests.swift
//  MachmanDesktopCoreTests
//
//  P12: after a reconnect the user hears which of their actions the lost connection cut off
//  — once, in their words — and nothing when only reads were in flight.
//

import Testing
import Foundation
import MachmanAPI
import MachmanClient
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct InterruptedActionsTests {

	@Test func readsAreNotTheUsersActions() {
		for method in [RPCMethod.vmList, .preview, .daemonRetire, .vmGet, .eventsSubscribe] {
			#expect(InterruptedActions.phrase(InterruptedCall(method: method, vm: "Debian"))
				== nil)
		}
	}

	@Test func actionsAreSaidAsTheUserDidThem() {
		#expect(InterruptedActions.phrase(InterruptedCall(method: .start, vm: "Debian"))
			== "starting Debian")
		#expect(InterruptedActions.phrase(InterruptedCall(method: .vmDelete, vm: "Alpine"))
			== "deleting Alpine")
		#expect(InterruptedActions.phrase(InterruptedCall(method: .vmCopy, vm: "Fedora"))
			== "duplicating Fedora")
		#expect(InterruptedActions.phrase(InterruptedCall(method: .vmCreate, vm: nil))
			== "creating a VM")
		#expect(InterruptedActions.phrase(InterruptedCall(method: .setHardware, vm: "Debian"))
			== "changing Debian")
		#expect(InterruptedActions.phrase(InterruptedCall(method: .stop, vm: nil))
			== "stopping a VM")
	}

	@Test func oneSentenceNamesTwoThenCounts() {
		let start = InterruptedCall(method: .start, vm: "Debian")
		let delete = InterruptedCall(method: .vmDelete, vm: "Alpine")
		let copy = InterruptedCall(method: .vmCopy, vm: "Fedora")
		let stop = InterruptedCall(method: .stop, vm: "Sequoia")
		#expect(InterruptedActions.message([start])
			== "Check whether starting Debian finished.")
		#expect(InterruptedActions.message([start, delete])
			== "Check whether starting Debian and deleting Alpine finished.")
		#expect(InterruptedActions.message([start, delete, copy, stop])
			== "Check whether starting Debian, deleting Alpine and 2 more finished.")
		#expect(InterruptedActions.message([start, start, InterruptedCall(method: .vmList,
			vm: nil)]) == "Check whether starting Debian finished.")
		#expect(InterruptedActions.message([InterruptedCall(method: .vmList, vm: nil)]) == nil)
	}

	@Test func theNextViewModelShowsOneAlert() async {
		let h = await DesktopHarness.make()
		h.viewModel.announceInterrupted([
			InterruptedCall(method: .start, vm: "Debian"),
			InterruptedCall(method: .vmList, vm: nil),
		])
		#expect(h.viewModel.presentedError?.title == "The connection to Machman Agent was lost")
		#expect(h.viewModel.presentedError?.message == "Check whether starting Debian finished.")
	}

	@Test func onlyReadsInFlightShowNothing() async {
		let h = await DesktopHarness.make()
		h.viewModel.announceInterrupted([InterruptedCall(method: .vmList, vm: nil)])
		h.viewModel.announceInterrupted([])
		#expect(h.viewModel.presentedError == nil)
	}
}
