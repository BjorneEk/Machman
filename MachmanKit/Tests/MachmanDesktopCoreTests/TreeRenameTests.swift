//
//  TreeRenameTests.swift
//  MachmanDesktopCoreTests
//
//  The tree's rename in place runs the inspector fields' checks (H37). Its disk and kernel
//  renames called the daemon directly: no trimming, an unchanged name sent anyway (and
//  toasted “Renamed to system”), a taken or invalid name explained only by an alert after
//  the round trip. They go through submitDiskRename / submitKernelTag / submitRename now.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct TreeRenameTests {
	private let disk = SidebarNode.disk("storage:system")

	private func alpine(_ h: DesktopHarness) throws -> VMInfo {
		try #require(h.viewModel.vms.first { $0.name == "Alpine" })
	}

	private func submit(
		_ h: DesktopHarness, _ node: SidebarNode, _ draft: String, on vm: VMInfo
	) -> Bool {
		h.viewModel.submitTreeRename(node, draft: draft, on: vm)
	}

	@Test func anUnchangedDiskNameSendsNothing() async throws {
		let h = await DesktopHarness.make()
		let vm = try alpine(h)
		#expect(h.viewModel.treeRenameProblem(disk, draft: "system", on: vm) == nil)
		#expect(!submit(h, disk, " system ", on: vm))
		try await Task.sleep(for: .milliseconds(50))
		#expect(!h.stub.calls.contains("renameDisk"))
		#expect(h.viewModel.toasts.isEmpty)
	}

	@Test func aPaddedDiskNameGoesOutTrimmed() async throws {
		let h = await DesktopHarness.make()
		let vm = try alpine(h)
		#expect(submit(h, disk, "  boot  ", on: vm))
		#expect(await eventually {
			h.stub.vms["Alpine"]?.disks.contains { $0.name == "boot" } == true
		})
	}

	@Test func aDiskNameWithAProblemIsExplainedAndNotSent() async throws {
		let h = await DesktopHarness.make()
		let vm = try alpine(h)
		#expect(h.viewModel.treeRenameProblem(disk, draft: ".x", on: vm)
			== "A disk name can’t start with a dot")
		#expect(!submit(h, disk, ".x", on: vm))
		try await Task.sleep(for: .milliseconds(50))
		#expect(!h.stub.calls.contains("renameDisk"))
	}

	@Test func aRunningVMsDiskSaysToStopFirst() async throws {
		let h = await DesktopHarness.make()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		#expect(h.viewModel.treeRenameProblem(disk, draft: "boot", on: debian)
			== debian.refusal(.renameDisk))
		#expect(debian.refusal(.renameDisk) != nil)
		#expect(!submit(h, disk, "boot", on: debian))
	}

	@Test func kernelTagsGoThroughTheTagChecks() async throws {
		let h = await DesktopHarness.make([Samples.kernelBoot()])
		let vm = try #require(h.viewModel.vms.first)
		let file = try #require(vm.boot.ownedKernels?.first {
			$0.tag == "6.12" && $0.role == .kernel
		})
		let node = SidebarNode.kernel(file.path)
		#expect(!submit(h, node, "6.12", on: vm))
		#expect(h.viewModel.treeRenameProblem(node, draft: "a/b", on: vm) != nil)
		#expect(!submit(h, node, "a/b", on: vm))
		try await Task.sleep(for: .milliseconds(50))
		#expect(!h.stub.calls.contains("renameKernelFile"))
		#expect(submit(h, node, "6.13", on: vm))
		#expect(await eventually { h.stub.calls.contains("renameKernelFile") })
	}

	@Test func anUnchangedRootNameSendsNothing() async throws {
		let h = await DesktopHarness.make()
		let vm = try alpine(h)
		#expect(!submit(h, .vmRoot, "Alpine ", on: vm))
		#expect(h.viewModel.treeRenameProblem(.vmRoot, draft: "Sequoia", on: vm)
			== "A VM named \u{201C}Sequoia\u{201D} already exists")
		try await Task.sleep(for: .milliseconds(50))
		#expect(!h.stub.calls.contains("renameVM"))
	}
}
