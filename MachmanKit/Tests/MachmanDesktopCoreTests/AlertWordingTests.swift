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

	// Q31: the confirmations' words moved from VMNavigationView into the prompt center
	// verbatim — title, message and buttons, with their roles.
	@Test("Q31: every confirmation reads as it did before the prompt center")
	func confirmationsKeepTheirWords() async throws {
		let h = await DesktopHarness.make()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		let disk = try #require(debian.disks.first { $0.owned == true })
		func reads(_ kind: Prompt.Kind) -> [String] {
			let content = Prompt(kind: kind).content(for: h.viewModel)
			return [content.title, content.message] + content.choices.map { choice in
				switch choice.role {
				case .destructive?: return "\(choice.title) (destructive)"
				case .cancel?: return "\(choice.title) (cancel)"
				case nil: return choice.title
				}
			}
		}
		#expect(reads(.deleteVM(debian)) == [
			"Delete \u{201C}Debian\u{201D}?", VMListViewModel.deleteVMMessage,
			"Delete VM (destructive)", "Cancel (cancel)",
		])
		#expect(reads(.deleteDisk(.init(vm: "Debian", disk: disk))) == [
			"Delete disk \u{201C}\(disk.name ?? "")\u{201D}?",
			"The backing file belongs to Debian and is deleted with it.",
			"Delete Disk (destructive)", "Cancel (cancel)",
		])
		#expect(reads(.deleteKernel(.init(vm: "Debian", path: "/k/vmlinuz", fileName: "vmlinuz")))
			== [
				"Delete \u{201C}vmlinuz\u{201D}?",
				"The file belongs to Debian and is removed from its directory.",
				"Delete File (destructive)", "Cancel (cancel)",
			])
		#expect(reads(.stop(PendingStop(vm: "Debian", mode: .force))) == [
			"Force stop \u{201C}Debian\u{201D}?",
			"Debian stops at once, like pulling its power cord.",
			"Force Stop (destructive)", "Cancel (cancel)",
		])
		let file = URL(fileURLWithPath: "/Users/demo/a.raw")
		#expect(reads(.diskAdd(.init(vm: "Debian", urls: [file]))) == [
			"Add \u{201C}a.raw\u{201D}?",
			"Copy a.raw into Debian (an independent copy that travels with the VM), or "
				+ "reference the original in place?",
			"Copy into VM", "Reference", "Cancel (cancel)",
		])
		#expect(reads(.forceStart(PendingForceStart(
			name: "Debian", headless: false, safe: false, message: "MAC in use"))) == [
			"MAC address conflict", "MAC in use", "Start Anyway", "Cancel (cancel)",
		])
	}
}

