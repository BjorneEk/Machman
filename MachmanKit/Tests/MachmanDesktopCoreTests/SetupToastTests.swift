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
}
