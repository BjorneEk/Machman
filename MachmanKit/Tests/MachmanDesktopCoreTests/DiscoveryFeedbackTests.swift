//
//  DiscoveryFeedbackTests.swift
//  MachmanDesktopCoreTests
//
//  F4: Re-run Address Discovery and Check Connection said something only when the address
//  CHANGED, so a guest without SSH, or one still at the same address, got silence. Now a
//  spinner shows at once and the outcome is always said: still at, answered at, or not yet.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct DiscoveryFeedbackTests {
	private let key = VMListViewModel.rediscoveryToastKey("Debian")

	private func message(_ h: DesktopHarness) -> String? {
		h.viewModel.toasts.first { $0.key == key }?.message
	}

	@Test func anUnchangedAddressSaysSo() async {
		let h = await DesktopHarness.make()
		h.viewModel.refreshSSH("Debian")
		#expect(h.viewModel.toasts.first { $0.key == key }?.spinner == true)
		#expect(message(h) == "Looking for Debian’s address…")
		h.stub.emit(.sshChanged(vm: "Debian"))
		#expect(await eventually { message(h) == "Debian is still at 192.168.64.7" })
	}

	@Test func aNewAddressUsesTheAnsweredToast() async {
		let h = await DesktopHarness.make()
		h.viewModel.refreshSSH("Debian")
		var debian = h.stub.vms["Debian"]!
		debian.ssh?.address = "192.168.64.9"
		h.stub.vms["Debian"] = debian
		h.stub.emit(.sshChanged(vm: "Debian"))
		#expect(await eventually {
			h.viewModel.toasts.contains { $0.message == "Debian answered — 192.168.64.9" }
		})
		#expect(message(h) == nil)
	}

	// A list refresh that isn't the answer leaves the spinner up.
	@Test func aReloadBeforeTheAnswerDoesNotFinish() async {
		let h = await DesktopHarness.make()
		h.viewModel.refreshSSH("Debian")
		let reloads = h.stub.calls.filter { $0 == "listVMs" }.count
		await h.store.reload()
		#expect(h.stub.calls.filter { $0 == "listVMs" }.count > reloads)
		#expect(await h.settled())
		#expect(message(h) == "Looking for Debian’s address…")
	}

	@Test func noAnswerSaysMachmanKeepsLooking() async {
		let h = await DesktopHarness.make()
		h.viewModel.rediscoveryWait = .seconds(1)
		h.viewModel.refreshSSH("Debian")
		#expect(await eventually {
			message(h) == "No address for Debian yet — Machman keeps looking"
		})
	}

	@Test func aRefusedRefreshAlerts() async {
		let h = await DesktopHarness.make()
		h.stub.fail("refreshSSH", with: MachmanError(
			code: .invalidState, message: "Debian isn't running"))
		h.viewModel.refreshSSH("Debian")
		#expect(await eventually { h.viewModel.presentedError != nil })
		#expect(message(h) == nil)
	}
}
