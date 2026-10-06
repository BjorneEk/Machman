//
//  SetupToastTests.swift
//  MachmanDesktopCoreTests
//
//  Since wave 2 every guest boot re-sends its setup report, and any new report stamp raised
//  "guest setup complete" again. A boot-time refresh replays the last run's outcome and
//  re-probes the rest, so the toast now follows the RUN: a changed outcome toasts, a refresh
//  stays quiet, an uninstall says "removed", and a v3+ guest's SSH half drifting at boot
//  (its address or hostname claims) no longer raises "SSH set up".
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct SetupToastTests {
	// Debian, running, guest setup ok from a v3 script.
	private func harness() async -> DesktopHarness {
		await DesktopHarness.make([Samples.linux("Debian", state: .running)])
	}

	// A new report lands (the host stamps it) with whatever `change` does to the setup half.
	private func report(
		_ h: DesktopHarness, _ change: (inout GuestSetupInfo) -> Void
	) async {
		var debian = h.stub.vms["Debian"]!
		var setup = debian.setup!
		setup.lastReportAt = Samples.epoch.addingTimeInterval(3_600)
		change(&setup)
		debian.setup = setup
		h.stub.vms["Debian"] = debian
		h.stub.emit(.setupChanged(vm: "Debian"))
		_ = await eventually {
			h.store.vms.first?.setup?.lastReportAt == Samples.epoch.addingTimeInterval(3_600)
		}
		try? await Task.sleep(for: .milliseconds(300))
	}

	private func setupToasts(_ h: DesktopHarness) -> [String] {
		h.viewModel.toasts.map(\.message).filter { $0.contains("guest setup") }
	}

	@Test func aBootRefreshThatChangesOnlyProbedStateIsQuiet() async {
		let h = await harness()
		await report(h) { setup in
			setup.consoles = [GuestConsoleInfo(device: "hvc0", login: "active")]
		}
		#expect(setupToasts(h).isEmpty)
	}

	@Test func aRunWithANewOutcomeToasts() async {
		let h = await harness()
		await report(h) { setup in
			setup.lastRunStatus = "partial"
			setup.errors = [GuestSetupError(step: "automount", message: "no virtiofs module")]
		}
		#expect(setupToasts(h) == ["Debian: guest setup partial — details in the inspector"])
	}

	@Test func aScriptUpdateToasts() async {
		let h = await harness()
		await report(h) { setup in setup.scriptVersion = 5 }
		#expect(setupToasts(h) == ["Debian: guest setup complete"])
	}

	@Test func anUninstallSaysRemoved() async {
		let h = await harness()
		await report(h) { setup in
			setup.installed = false
			setup.lastRunStatus = nil
		}
		#expect(setupToasts(h) == ["Debian: guest setup removed"])
	}

	// The SSH half of a v3+ report moves at boot too; only v2 guests (no setup half) still
	// get the SSH-only toast.
	@Test func anSSHOnlyDriftOnAV3GuestIsQuiet() async {
		let h = await harness()
		var debian = h.stub.vms["Debian"]!
		debian.ssh?.lastReportAt = Samples.epoch.addingTimeInterval(3_600)
		debian.ssh?.guestHostname = "debian-13"
		h.stub.vms["Debian"] = debian
		h.stub.emit(.sshChanged(vm: "Debian"))
		_ = await eventually { h.store.vms.first?.ssh?.guestHostname == "debian-13" }
		try? await Task.sleep(for: .milliseconds(300))
		#expect(!h.viewModel.toasts.contains { $0.message.contains("SSH set up") })
	}

	// W6 follow-up (review F10, wave r3w3): the SSH-only toast of a v2 guest (no setup half)
	// named the guest by its raw os-release id ("(debian)"); it names the OS, and leaves out
	// an id Machman doesn't know rather than show it.
	@Test("W6: a v2 guest's SSH setup toast names its OS, never the raw id")
	func theSSHSetupToastNamesTheOS() async {
		var v2 = Samples.linux("Debian", state: .running)
		v2.setup = nil
		var mystery = Samples.linux("Kali", state: .running)
		mystery.setup = nil
		let h = await DesktopHarness.make([v2, mystery])
		for (name, os) in [("Debian", "debian"), ("Kali", "mystery-linux")] {
			var vm = h.stub.vms[name]!
			vm.ssh?.lastReportAt = Samples.epoch.addingTimeInterval(3_600)
			vm.ssh?.guestUser = "root"
			vm.ssh?.guestOS = os
			h.stub.vms[name] = vm
			h.stub.emit(.sshChanged(vm: name))
		}
		_ = await eventually {
			h.viewModel.toasts.filter { $0.message.contains("SSH set up") }.count == 2
		}
		let toasts = h.viewModel.toasts.map(\.message).filter { $0.contains("SSH set up") }
		#expect(toasts.sorted() == ["Debian: SSH set up for root (Debian)",
			"Kali: SSH set up for root"], "\(toasts)")
	}
}
