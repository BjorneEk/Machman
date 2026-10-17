//
//  QuestionToastRowTests.swift
//  MachmanDesktopCoreTests
//
//  Manual rows whose question or toast the view model decides: Force Stop from the menu asks
//  and only the answer stops the VM (W2-26), a second alert waits for the first and its
//  re-present delay (W1-12), a guest key awaiting approval toasts once and points at SSH
//  (G15), Add Guest Setup is offered only while absent and says Added (W2-19), and an
//  unreached VM offers stopping but no Start or Delete (R3W2-8). Dialogs, alerts and toasts
//  don't render; what they show is the view model's state, which is what runs here.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// L1: view model (DesktopHarness + StubMachman).
@MainActor
struct QuestionToastRowTests {
	@Test("W2-26: Force Stop from the menu asks first and only its answer stops the VM")
	func forceStopAsksFirst() async throws {
		let h = await DesktopHarness.make()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		// Run ▸ Force Stop… (⌥⌘.) asks; the toolbar's immediate stop is another path.
		h.viewModel.requestStop(debian, mode: .force)
		let pending = try #require(h.viewModel.pendingStop)
		#expect(pending.mode == .force)
		#expect(pending.title == "Force stop \u{201C}Debian\u{201D}?")
		#expect(pending.confirmLabel == "Force Stop")
		try await Task.sleep(for: .milliseconds(50))
		#expect(!h.stub.calls.contains("stop"))
		#expect(h.stub.vms["Debian"]?.state == .running)
		h.viewModel.confirmStop(pending)
		#expect(h.viewModel.pendingStop == nil)
		#expect(await eventually { h.stub.vms["Debian"]?.state == .stopped })
	}

	@Test("W1-12: a second alert waits for the first and its re-present delay")
	func aSecondAlertWaitsItsTurn() async throws {
		let h = await DesktopHarness.make()
		h.viewModel.present(message: "a", while: "Doing A")
		h.viewModel.present(message: "b", while: "Doing B")
		#expect(h.viewModel.presentedError?.message == "a")
		let clock = ContinuousClock()
		let dismissed = clock.now
		h.viewModel.isErrorPresented = false
		#expect(await eventually { h.viewModel.presentedError?.message == "b" })
		// A lower bound only: the alert animates out before the next one comes in.
		let delay = PromptCenter.representDelay
		#expect(clock.now - dismissed >= delay * 0.9, "\(clock.now - dismissed)")
		#expect(h.viewModel.isErrorPresented)
	}

	@Test("G15: a guest key awaiting approval toasts once and points at SSH")
	func anApprovalToastsOnce() async throws {
		let h = await DesktopHarness.make([Samples.linux("Debian", state: .running)])
		let message = "Debian asks to log in to this Mac \u{2014} approve it in the SSH section"
		var debian = try #require(h.stub.vms["Debian"])
		debian.ssh?.reverseState = .pending
		debian.ssh?.reversePublicKey = Samples.reverseKeyLine
		h.stub.vms["Debian"] = debian
		h.stub.emit(.sshChanged(vm: "Debian"))
		#expect(await eventually { h.viewModel.toasts.contains { $0.message == message } })
		// The same pending key reported again (a boot refresh) asks nothing new.
		let lists = h.stub.calls.filter { $0 == "listVMs" }.count
		h.stub.emit(.sshChanged(vm: "Debian"))
		#expect(await eventually { h.stub.calls.filter { $0 == "listVMs" }.count > lists })
		try await Task.sleep(for: .milliseconds(100))
		#expect(h.viewModel.toasts.filter { $0.message == message }.count == 1)
		let asks = h.viewModel.activity.entries.filter {
			$0.detail == "Asks to log in to this Mac \u{2014} approve it in the SSH section"
		}
		#expect(asks.count == 1)
	}

	@Test("W2-19: Installers offers Add Guest Setup only while absent, and says Added")
	func addGuestSetupOnlyWhileAbsent() async throws {
		let h = await DesktopHarness.make([Samples.bareLinux()])
		#expect(h.viewModel.vms.first?.canAddGuestSetup == true)
		h.viewModel.addDevice("Bare", kind: .guestSetup)
		#expect(await eventually {
			h.viewModel.toasts.contains { $0.message == "Added Guest Setup" }
		})
		#expect(await eventually { h.viewModel.vms.first?.canAddGuestSetup == false })
	}

	@Test("R3W2-8: an unreached VM offers Shut Down and Force Stop but no Start or Delete")
	func anUnreachedVMOffersOnlyStopping() async throws {
		let h = await DesktopHarness.make(Samples.libraryWithUnreachedHost())
		h.viewModel.select(name: "Debian")
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		#expect(debian.state == .unknown)
		#expect(debian.mayBeRunning)
		#expect(debian.menuBarCanStop)
		#expect(!h.viewModel.canStart(debian))
		#expect(!CommandTarget(viewModel: h.viewModel, window: .main)
			.canDeleteVM(editingText: false))
		#expect(debian.refusal(.deleteVM) == VMInfo.unreachedHelp)
	}
}
