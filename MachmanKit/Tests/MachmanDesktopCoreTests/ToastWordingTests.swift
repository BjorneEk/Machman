//
//  ToastWordingTests.swift
//  MachmanDesktopCoreTests
//
//  W4: the toasts drifted — “Renamed to…”, “Disk renamed to…”, “Mount tag changed to…”,
//  “Re-tagged…”; “Added disk” beside “Added Keyboard”; “Guest-setup state reset” beside
//  “guest setup complete”; “SSH: connecting to X…” in a slot that otherwise reads “X: SSH
//  ready”; and Deny on a pending login request said “Revoked”. One pattern per family now
//  (wording.md 8), pinned here string for string.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct ToastWordingTests {
	private func toasted(_ h: DesktopHarness, _ text: String) async -> Bool {
		await eventually { h.viewModel.toasts.contains { $0.message == text } }
	}

	@Test func everyRenameSaysRenamedTo() async throws {
		let h = await DesktopHarness.make([Samples.linux("Debian"), Samples.kernelBoot()])
		h.viewModel.renameDisk("Debian", diskID: "storage:system", newName: "root")
		#expect(await toasted(h, "Renamed to \u{201C}root\u{201D}"))

		let mount = try #require(h.viewModel.vms.first { $0.name == "Debian" }?.mounts.first)
		h.viewModel.setMountTag("Debian", mountID: mount.id, tag: "code")
		#expect(await toasted(h, "Renamed to \u{201C}code\u{201D}"))

		// The stub keeps the file where it was, so a re-tag to its own tag finds it.
		let kernel = try #require(h.viewModel.vms.first { $0.name == "Kernel Lab" }?
			.boot.ownedKernels?.first { $0.tag == "6.12" && $0.role == .kernel })
		h.viewModel.renameKernelTag("Kernel Lab", path: kernel.path, tag: "6.12")
		#expect(await toasted(h, "Renamed to \u{201C}6.12\u{201D}"))

		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		h.viewModel.requestRename(debian, to: "Debian 2", profiles: h.profiles)
		#expect(await toasted(h, "Renamed to \u{201C}Debian 2\u{201D}"))
	}

	@Test func addsAndRemovesNameTheThingInRunningText() async {
		let h = await DesktopHarness.make([Samples.linux("Debian")])
		h.viewModel.addDevice("Debian", kind: .entropy)
		#expect(await toasted(h, "Added entropy"))
		h.viewModel.removeDevice("Debian", kind: .keyboard)
		#expect(await toasted(h, "Removed keyboard"))
		h.viewModel.addDevice("Debian", kind: .rosetta)
		#expect(await toasted(h, "Added Rosetta"))
		h.viewModel.addConsolePort("Debian")
		#expect(await toasted(h, "Added console port"))
	}

	@Test func deviceKindsReadAsCommonNounsExceptNames() {
		#expect(DeviceKind.allKinds.map(\.inlineLabel) == [
			"keyboard", "trackpad", "pointer", "display", "mic", "audio", "network",
			"clipboard", "entropy", "Rosetta", "Console Login", "SSH Setup", "Guest Setup",
		])
	}

	@Test func resetsReadAlike() async {
		let h = await DesktopHarness.make([Samples.linux("Debian")])
		h.viewModel.resetSetup("Debian")
		#expect(await toasted(h, "Guest setup state reset for Debian"))
		h.viewModel.resetSSH("Debian")
		#expect(await toasted(h, "SSH state reset for Debian"))
	}

	@Test func theSSHSlotKeepsOnePattern() async throws {
		let h = await DesktopHarness.make([Samples.linux("Debian", state: .running)])
		var debian = try #require(h.stub.vms["Debian"])
		debian.ssh?.reachability = .waiting
		h.stub.vms["Debian"] = debian
		h.stub.emit(.sshChanged(vm: "Debian"))
		#expect(await toasted(h, "Debian: SSH connecting…"))
		debian.ssh?.reachability = .ready
		h.stub.vms["Debian"] = debian
		h.stub.emit(.sshChanged(vm: "Debian"))
		#expect(await toasted(h, "Debian: SSH ready"))
	}

	@Test func guestAccessToastsSayWhatChanged() async {
		let approve = await DesktopHarness.make([Samples.linuxReverse(.pending)])
		approve.viewModel.setSSHReverseApproved("Debian", approved: true)
		#expect(await toasted(approve, "Approved Debian’s access to this Mac"))

		let deny = await DesktopHarness.make([Samples.linuxReverse(.pending)])
		deny.viewModel.setSSHReverseApproved("Debian", approved: false)
		#expect(await toasted(deny, "Denied Debian’s access to this Mac"))

		let revoke = await DesktopHarness.make([Samples.linuxReverseApproved()])
		revoke.viewModel.setSSHReverseApproved("Debian", approved: false)
		#expect(await toasted(revoke, "Revoked Debian’s access to this Mac"))
	}
}
