//
//  RenameFieldTests.swift
//  MachmanDesktopCoreTests
//
//  PR8's inspector half: the VM name, disk name and mount tag fields showed a refused name
//  as an alert. A draft the rules or the list refuse is explained under the field and Return
//  sends nothing; a refusal the daemon sends back comes to the field, not to an alert.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct RenameFieldTests {
	private let mountID = "7B0E4F52-3C1A-4D55-9E0B-2A6C1D9F0A11"

	@Test func liveReasonsUseTheDaemonsWords() async throws {
		let h = await DesktopHarness.make(Samples.library().filter { $0.name != "Alpine" }
			+ [Samples.linuxTwoDisks()])
		let alpine = try #require(h.viewModel.vms.first { $0.name == "Alpine" })
		#expect(h.viewModel.vmRenameProblem("Alpine", for: alpine) == nil)
		#expect(h.viewModel.vmRenameProblem(" Alpine ", for: alpine) == nil)
		#expect(h.viewModel.vmRenameProblem("a/b", for: alpine)
			== "A VM name can't contain \u{201C}/\u{201D}")
		#expect(h.viewModel.vmRenameProblem("Sequoia", for: alpine)
			== "A VM named \u{201C}Sequoia\u{201D} already exists")
		let disk = { (draft: String) in
			h.viewModel.diskRenameProblem(draft, diskID: "storage:system", on: alpine)
		}
		#expect(disk("system") == nil)
		#expect(disk("data") == "This VM already has a disk named \u{201C}data\u{201D}")
		#expect(disk(".x") == "A disk name can't start with a dot")
		#expect(disk("") == "A disk name can't be empty")
		#expect(disk("scratch") == nil)
		let tag = { (draft: String) in
			h.viewModel.mountTagProblem(draft, mountID: mountID, on: alpine)
		}
		#expect(tag("src") == nil)
		#expect(tag("GuestSetup") == "\u{201C}GuestSetup\u{201D} is reserved by Machman")
		#expect(tag("a:b") == "A mount tag can't contain \u{201C}:\u{201D}")
		#expect(tag("code") == nil)
	}

	@Test func aRefusedDraftSendsNothingAndRaisesNoAlert() async throws {
		let h = await DesktopHarness.make()
		let alpine = try #require(h.viewModel.vms.first { $0.name == "Alpine" })
		var refusals: [String] = []
		#expect(!h.viewModel.submitRename(
			alpine, draft: "a/b", profiles: h.profiles, refused: { refusals.append($0) }))
		#expect(!h.viewModel.submitDiskRename(
			alpine, diskID: "storage:system", draft: ".x", refused: { refusals.append($0) }))
		#expect(!h.viewModel.submitMountTag(
			alpine, mountID: mountID, draft: "GuestSetup", refused: { refusals.append($0) }))
		try await Task.sleep(for: .milliseconds(50))
		#expect(h.viewModel.presentedError == nil)
		#expect(refusals.isEmpty)
		#expect(!h.stub.calls.contains("renameVM"))
		#expect(!h.stub.calls.contains("renameDisk"))
		#expect(!h.stub.calls.contains("setMountTag"))
	}

	@Test func anUnchangedNameRevertsWithoutSending() async throws {
		let h = await DesktopHarness.make()
		let alpine = try #require(h.viewModel.vms.first { $0.name == "Alpine" })
		var reverts = 0
		#expect(!h.viewModel.submitRename(
			alpine, draft: " Alpine ", profiles: h.profiles, reverted: { reverts += 1 },
			refused: { _ in }))
		#expect(reverts == 1)
		try await Task.sleep(for: .milliseconds(50))
		#expect(!h.stub.calls.contains("renameVM"))
	}

	@Test func aDaemonRefusalComesBackToTheField() async throws {
		let h = await DesktopHarness.make()
		let alpine = try #require(h.viewModel.vms.first { $0.name == "Alpine" })
		let busy = "Alpine is busy"
		var got: String?
		var reverts = 0
		h.stub.fail("renameVM", with: MachmanError(code: .invalidState, message: busy))
		#expect(h.viewModel.submitRename(
			alpine, draft: "Alpine 2", profiles: h.profiles, reverted: { reverts += 1 },
			refused: { got = $0 }))
		#expect(await eventually { got == busy })
		#expect(await eventually { reverts == 1 })
		#expect(h.viewModel.presentedError == nil)

		got = nil
		h.stub.fail("renameDisk", with: MachmanError(code: .invalidState, message: busy))
		#expect(h.viewModel.submitDiskRename(
			alpine, diskID: "storage:system", draft: "root", refused: { got = $0 }))
		#expect(await eventually { got == busy })
		#expect(h.viewModel.presentedError == nil)

		got = nil
		h.stub.fail("setMountTag", with: MachmanError(code: .alreadyExists, message: busy))
		#expect(h.viewModel.submitMountTag(
			alpine, mountID: mountID, draft: "code", refused: { got = $0 }))
		#expect(await eventually { got == busy })
		#expect(h.viewModel.presentedError == nil)
	}

	@Test func anAcceptedRenameIsSent() async throws {
		let h = await DesktopHarness.make()
		let alpine = try #require(h.viewModel.vms.first { $0.name == "Alpine" })
		#expect(h.viewModel.submitDiskRename(
			alpine, diskID: "storage:system", draft: " root ", refused: { _ in }))
		#expect(await eventually {
			h.stub.vms["Alpine"]?.disks.contains { $0.name == "root" } == true
		})
		#expect(h.viewModel.submitMountTag(
			alpine, mountID: mountID, draft: "code", refused: { _ in }))
		#expect(await eventually {
			h.stub.vms["Alpine"]?.mounts.first?.tag == "code"
		})
		#expect(h.viewModel.submitRename(
			alpine, draft: "Alpine 2", profiles: h.profiles, refused: { _ in }))
		#expect(await eventually { h.viewModel.selectedName == "Alpine 2" })
	}

	@Test func aRunningVMSendsNothing() async throws {
		let h = await DesktopHarness.make()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		#expect(!h.viewModel.submitRename(
			debian, draft: "Debian 2", profiles: h.profiles, refused: { _ in }))
		#expect(!h.viewModel.submitDiskRename(
			debian, diskID: "storage:system", draft: "root", refused: { _ in }))
		try await Task.sleep(for: .milliseconds(50))
		#expect(!h.stub.calls.contains("renameVM"))
		#expect(!h.stub.calls.contains("renameDisk"))
	}
}
