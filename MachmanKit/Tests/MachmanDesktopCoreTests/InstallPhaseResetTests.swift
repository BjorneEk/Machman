//
//  InstallPhaseResetTests.swift
//  MachmanDesktopCoreTests
//
//  The install phases a session's events left behind (F11). They lived as long as the app:
//  an agent that went away mid-download (Replace, Quit, a crash) left its last .downloading
//  phase outranking the new agent's "interrupted" for good — a frozen card, Start blocked —
//  and a deleted VM's phase passed to the next VM that took its name. Phases now start over
//  with each connection and leave with their VM.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct InstallPhaseResetTests {
	private func sequoia(_ h: DesktopHarness) -> VMInfo? {
		h.viewModel.vms.first { $0.name == "Sequoia" }
	}

	@Test("F11: an agent restart mid-install leaves no frozen install card")
	func aRestartMidInstallUnfreezes() async throws {
		let h = await DesktopHarness.make()
		h.stub.emit(.installPhaseChanged(vm: "Sequoia", phase: Samples.downloadingMacInstall()))
		#expect(await eventually { sequoia(h).map(h.viewModel.isInstalling) == true })
		// The agent that answers next has no live install: it lists the run as cut short.
		var info = try #require(h.stub.vms["Sequoia"])
		info.boot.macInstallState = MacInstallState(kind: .interrupted)
		h.stub.vms["Sequoia"] = info
		h.store.attach(api: h.stub)
		h.operations.attach(api: h.stub)
		#expect(await eventually {
			sequoia(h).map { h.viewModel.installPhase(for: $0).kind } == .interrupted
		})
		#expect(sequoia(h).map(h.viewModel.isInstalling) == false)
		#expect(h.operations.installPhases["Sequoia"] == nil)   // no corner card
	}

	@Test("F11: a new VM under a deleted VM's name inherits no install phase")
	func aReusedNameStartsClean() async throws {
		let h = await DesktopHarness.make()
		h.stub.emit(.installPhaseChanged(
			vm: "Sequoia", phase: InstallPhase(kind: .failed, message: "The download failed")))
		#expect(await eventually {
			sequoia(h).map { h.viewModel.installPhase(for: $0).kind } == .failed
		})
		try await h.stub.deleteVM(named: "Sequoia")
		#expect(await eventually { !h.viewModel.hasVM("Sequoia") })
		var fresh = Samples.macOS("Sequoia")
		fresh.boot.macInstallState = nil   // a new macOS VM, never installed
		h.stub.vms["Sequoia"] = fresh
		h.stub.emit(.listChanged)
		#expect(await eventually { h.viewModel.hasVM("Sequoia") })
		#expect(sequoia(h).map { h.viewModel.installPhase(for: $0).kind } == .idle)
	}
}
