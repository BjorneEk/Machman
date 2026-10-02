//
//  AlertWordingTests.swift
//  MachmanDesktopCoreTests
//
//  W4 and X7: a failure alert is titled by the action that failed, with user-chosen names
//  quoted (wording.md 5, 8). The Terminal alias toggle's failure read “Updating the SSH alias
//  failed” whichever way it went, a Shut Down read “Stopping X failed”, and internals leaked
//  (“the setup payload”). Delete VM… asked in two sentences.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct AlertWordingTests {
	private let refusal = MachmanError(code: .ioFailure, message: "no can do")

	private func titled(_ h: DesktopHarness, _ title: String) async -> Bool {
		await eventually { h.viewModel.presentedError?.title == title }
	}

	private func dismiss(_ h: DesktopHarness) async {
		h.viewModel.isErrorPresented = false
		_ = await eventually { h.viewModel.presentedError == nil }
	}

	@Test func theAliasToggleNamesWhatFailed() async {
		let h = await DesktopHarness.make([Samples.linux("Debian")])
		h.stub.fail("setSSH", with: refusal)
		h.viewModel.setSSHIntegration("Debian", enabled: true)
		#expect(await titled(
			h, "Adding \u{201C}debian.machman\u{201D} to your SSH config failed"))
		await dismiss(h)
		h.stub.fail("setSSH", with: refusal)
		h.viewModel.setSSHIntegration("Debian", enabled: false)
		#expect(await titled(
			h, "Removing \u{201C}debian.machman\u{201D} from your SSH config failed"))
	}

	@Test func stopsAreTitledByTheirMode() async {
		let h = await DesktopHarness.make([Samples.linux("Debian", state: .running)])
		h.stub.fail("stop", with: refusal)
		h.viewModel.stopVM("Debian", mode: .soft)
		#expect(await titled(h, "Shutting down \u{201C}Debian\u{201D} failed"))
		await dismiss(h)
		h.stub.fail("stop", with: refusal)
		h.viewModel.stopVM("Debian", mode: .force)
		#expect(await titled(h, "Force stopping \u{201C}Debian\u{201D} failed"))
	}

	@Test func actionsAreNamedNotTheirPlumbing() async {
		let h = await DesktopHarness.make([Samples.linux("Debian", state: .running)])
		h.stub.fail("setSetupServed", with: refusal)
		h.viewModel.setSetupServed("Debian", serve: true)
		#expect(await titled(h, "Changing the reinstall setting failed"))
		await dismiss(h)
		h.stub.fail("refreshSSH", with: refusal)
		h.viewModel.refreshSSH("Debian")
		#expect(await titled(h, "Looking for the address of \u{201C}Debian\u{201D} failed"))
		await dismiss(h)
		h.stub.fail("resetSetup", with: refusal)
		h.viewModel.resetSetup("Debian")
		#expect(await titled(h, "Resetting guest setup state failed"))
	}

	@Test func deletingAVMAsksInOneSentence() {
		#expect(VMListViewModel.deleteVMTitle("dev copy") == "Delete \u{201C}dev copy\u{201D}?")
		#expect(VMListViewModel.deleteVMMessage
			== "The VM and the files it owns are deleted permanently.")
	}
}
