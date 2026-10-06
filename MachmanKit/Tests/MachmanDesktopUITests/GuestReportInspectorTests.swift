//
//  GuestReportInspectorTests.swift
//  MachmanDesktopUITests
//
//  What the inspectors make of a guest's setup report, read from the real views hosted
//  offscreen over sample reports: a failed run (S6b), sshfs before and after the guest → Mac
//  approval (S11), the Guest Setup status block from no report to a partial run and the
//  checkmark it folds behind (G12), the features list (G13), the Serial group's reported
//  logins and the mounts' badges and kind (G14), and the guest key's fingerprint above its
//  Approve… (W3-28). The guest's own side of each report is the lab's (L2/L3).
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
struct GuestReportInspectorTests {
	private func setup(_ vm: VMInfo) async throws -> AXSnapshot {
		let h = await UIHarness.make([vm])
		return try await h.snapshot(
			GuestSetupInspector(viewModel: h.viewModel, vm: h.vm(vm.name)),
			width: 320, height: 820)
	}

	private func ssh(_ vm: VMInfo) async throws -> AXSnapshot {
		let h = await UIHarness.make([vm])
		return try await h.snapshot(
			SSHInspector(viewModel: h.viewModel, vm: h.vm(vm.name)), width: 320, height: 820)
	}

	private func reads(_ tree: AXSnapshot, _ text: String) -> Bool {
		tree.find(text: text) != nil
	}

	@Test("S6b: a failed setup run reads Last run failed with its error")
	func aFailedRunReadsFailed() async throws {
		let tree = try await setup(Samples.failedSetupRun())
		#expect(reads(tree, "Last run failed"), "\(tree.dump())")
		#expect(reads(tree, "Errors (1)"))
		// A failed run keeps the installer served: its commands come back.
		#expect(reads(tree, "Linux"))
		#expect(reads(tree, "Serving because the last run failed."))
		#expect(!reads(tree, "Installed \u{2014} the script ran in this guest."))
	}

	@Test("S11: sshfs reads 'needs guest → Mac approval' until the key is approved")
	func sshfsWaitsForTheApproval() async throws {
		let pending = try await ssh(Samples.linuxSSHFS(.pending))
		#expect(reads(pending, "Available \u{2014} needs guest \u{2192} Mac approval"),
			"\(pending.dump())")
		let approved = try await ssh(Samples.linuxSSHFS(.approved))
		#expect(reads(approved, "Available"), "\(approved.dump())")
		#expect(!reads(approved, "Available \u{2014} needs guest \u{2192} Mac approval"))
	}

	@Test("G12: Guest Setup reads Not installed, then the run's status block")
	func theStatusBlockFollowsTheReport() async throws {
		let none = try await setup(Samples.setupNotInstalled())
		#expect(reads(none, "Not installed"), "\(none.dump())")
		#expect(reads(none, "No report yet \u{2014} run the installer in the guest."))

		let partial = try await setup(Samples.partialSetupRun())
		#expect(reads(partial, "Installed, with gaps"), "\(partial.dump())")
		#expect(reads(partial, "Debian 13, systemd"))   // the OS by name, not its id (W6)
		#expect(reads(partial, "v3"))
		#expect(reads(partial, "Errors (1)"))
		#expect(!reads(partial, "No report yet \u{2014} run the installer in the guest."))
	}

	@Test("G12: an installed setup folds behind its checkmark until reinstall")
	func anInstalledSetupFolds() async throws {
		let installed = try await setup(Samples.linux("Debian", state: .running))
		#expect(reads(installed, "Installed \u{2014} the script ran in this guest."),
			"\(installed.dump())")
		let toggle = try #require(installed.find(text: "Allow reinstall or update")
			?? installed.find(label: "Allow reinstall or update"))
		#expect(toggle.value == "0")
		#expect(!reads(installed, "Linux"))
		#expect(!reads(installed, "FreeBSD / OpenBSD"))

		let reinstall = try await setup(Samples.kernelBootReinstall())
		let run = GuestSetupCommands.run(.linux, shareMounted: true)
		#expect(reads(reinstall, run), "\(reinstall.dump())")
		#expect(reads(reinstall, "Run in the guest (the share automounts):"))
	}

	@Test("G13: the features list splits what the guest can and can't do")
	func theFeaturesSplit() async throws {
		let tree = try await setup(Samples.partialSetupRun())
		for title in ["Console logins", "SSH", "sshfs"] {
			#expect(reads(tree, title), "no \(title) row: \(tree.dump())")
		}
		#expect(reads(tree, "hvc0"), "a configured feature's detail")
		#expect(reads(tree, "Not configured"), "sshfs is available but not set up")
		#expect(reads(tree, "Unavailable (1)"))
	}

	@Test("G14: the Serial group lists each console's reported login and kernel")
	func theSerialGroupListsLogins() async throws {
		let h = await UIHarness.make([Samples.linuxConsolesReported()])
		let tree = try await h.snapshot(
			SerialGroupInspector(viewModel: h.viewModel, vm: h.vm("Debian")),
			width: 320, height: 820)
		for (device, summary) in [
			("/dev/hvc0", "Login active (automatic)"),
			("/dev/hvc1", "Login configured (next boot)"),
			("/dev/hvc2", "No login"),
			("/dev/hvc3", "Not present in the guest"),
		] {
			#expect(reads(tree, device), "\(device): \(tree.dump())")
			#expect(reads(tree, summary), "\(device): \(summary)")
		}
		#expect(reads(tree, "Kernel"))
		#expect(reads(tree, "Kernel (next boot)"))
		#expect(reads(tree, "Login states come from the last guest setup run."))
	}

	@Test("G14: mount rows badge sshfs and automount; macOS hides the kind picker")
	func mountRowsBadgeTheirKind() async throws {
		let h = await UIHarness.make([Samples.linuxWithMounts(), Samples.macOSWithMount()])
		let rows = try await h.snapshot(
			TreeSectionProbe(harness: h, vm: h.vm("Debian")) {
				AnyView(TreeStorageSection(ctx: $0))
			})
		let helps = rows.all.compactMap(\.help)
		#expect(helps.contains("sshfs \u{2014} the guest mounts this over its SSH link"),
			"\(helps)")
		#expect(helps.contains("Mounts at boot at /mnt/machman/src"), "\(helps)")

		let linux = try await h.snapshot(
			MountInspector(
				viewModel: h.viewModel, vm: h.vm("Debian"), mountID: Samples.notesMountID),
			width: 320, height: 820)
		#expect(Self.kindPicker(linux)?.text == "sshfs", "\(linux.dump())")
		#expect(linux.find(role: "AXStaticText", text: "Kind") != nil)
		let mac = try await h.snapshot(
			MountInspector(
				viewModel: h.viewModel, vm: h.vm("Sequoia"), mountID: Samples.srcMountID),
			width: 320, height: 820)
		#expect(Self.kindPicker(mac) == nil, "\(mac.dump())")
		#expect(mac.find(role: "AXStaticText", text: "Kind") == nil)
		#expect(mac.find(role: "AXButton", text: "Remove mount \u{2014} the folder stays") != nil,
			"the inspector itself showed: \(mac.dump())")
	}

	// The Kind picker: a pop-up carrying the kinds' tooltip, its value the mount's kind.
	private static func kindPicker(_ tree: AXSnapshot) -> AXSnapshot? {
		tree.all.first {
			$0.role == "AXPopUpButton" && $0.help?.hasPrefix("virtiofs rides") == true
		}
	}

	@Test("W3-28: the guest key's fingerprint stays above Approve…")
	func theFingerprintSitsAboveApprove() async throws {
		for state in [SSHInfo.ReverseState.pending, .denied] {
			let tree = try await ssh(Samples.linuxReverse(state))
			let fingerprint = try #require(
				tree.all.first { $0.text?.hasPrefix("SHA256:") == true }?.frame,
				"\(state): \(tree.dump())")
			let approve = try #require(
				tree.find(role: "AXButton", text: "Approve\u{2026}")?.frame, "\(state)")
			#expect(fingerprint.minY < approve.minY, "\(state): \(fingerprint) vs \(approve)")
		}
	}
}
