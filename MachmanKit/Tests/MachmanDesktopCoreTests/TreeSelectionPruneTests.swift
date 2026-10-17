//
//  TreeSelectionPruneTests.swift
//  MachmanDesktopCoreTests
//
//  The tree selection follows the list (T15): it was pruned only on a VM switch and a tab
//  close, so rows whose entity went away stayed selected, and a batch Enable/Disable over
//  them sent ids the daemon no longer knew (a notFound alert). A list refresh now drops gone
//  nodes (a renamed disk or kernel file stays selected under its new id), and the batch
//  sends only what still exists.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct TreeSelectionPruneTests {
	private let mountID = "7B0E4F52-3C1A-4D55-9E0B-2A6C1D9F0A11"
	private let lab = "\(Samples.vmsRoot)/Kernel Lab/kernels"

	private func selecting(_ name: String) async -> DesktopHarness {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: name)
		return h
	}

	private func change(_ h: DesktopHarness, _ name: String, _ edit: (inout VMInfo) -> Void) {
		guard var vm = h.stub.vms[name] else { return }
		edit(&vm)
		h.stub.vms[name] = vm
		h.stub.emit(.listChanged)
	}

	@Test func aRemovedDiskLeavesTheSelection() async {
		let h = await selecting("Debian")
		h.viewModel.treeSelection = [.disk("storage:system"), .mount(mountID)]
		change(h, "Debian") { $0.disks.removeAll { $0.id == "storage:system" } }
		#expect(await eventually { h.viewModel.treeSelection == [.mount(mountID)] })
	}

	// The list can land before renameDisk's reply repoints the selection itself.
	@Test func aRenamedDiskStaysSelected() async {
		let h = await selecting("Debian")
		h.viewModel.treeSelection = [.disk("storage:system")]
		change(h, "Debian") { vm in
			guard let i = vm.disks.firstIndex(where: { $0.id == "storage:system" }) else { return }
			vm.disks[i].id = "storage:root"
			vm.disks[i].name = "root"
		}
		#expect(await eventually { h.viewModel.treeSelection == [.disk("storage:root")] })
	}

	@Test func batchEnableSkipsGoneEntities() async throws {
		let h = await selecting("Debian")
		let vm = try #require(h.viewModel.selected)
		h.viewModel.treeSelection = [.disk("storage:system"), .disk("storage:gone"), .mount("nope")]
		h.viewModel.setSelectionEnabled(false, vm: vm)
		#expect(await eventually { h.stub.enabledChanges.count == 1 })
		let sent = try #require(h.stub.enabledChanges.first)
		#expect(sent.disks == ["storage:system": false])
		#expect(sent.mounts == nil)
		for _ in 0..<10 { await Task.yield() }
		#expect(h.viewModel.presentedError == nil)
	}

	@Test func aDeletedKernelFileIsDropped() async throws {
		let h = await selecting("Kernel Lab")
		let path = "\(lab)/kernel/6.6-lts/Image"
		h.viewModel.treeSelection = [.kernel(path)]
		_ = try await h.stub.deleteKernelFile(vm: "Kernel Lab", path: path)
		#expect(await eventually { h.viewModel.treeSelection.isEmpty })
	}

	// Back to EFI with every file deleted: the daemon still serves the draft, emptied (the
	// state this test once modeled as no draft at all, which hid N3 — review 4).
	@Test func theKernelGroupGoesWithKernelBoot() async {
		let h = await selecting("Kernel Lab")
		h.viewModel.treeSelection = [.group("Kernel"), .disk("storage:system")]
		change(h, "Kernel Lab") { vm in
			vm.boot.mode = .efi
			vm.boot.kernel = KernelSettings(kernelPath: "", initrdPath: nil, commandLine: "")
			vm.boot.ownedKernels = []
		}
		#expect(await eventually { h.viewModel.treeSelection == [.disk("storage:system")] })
	}

	// T28: only SSH, Serial and Kernel groups were pruned; a selected Mounts (Disks, Devices,
	// Installers) group whose last row went kept its selection after its section hid, and
	// the inspector fell back to the VM's with nothing highlighted in the tree.
	@Test("T28: a selected Mounts group goes with its last mount")
	func aGroupGoesWithItsLastRow() async {
		let h = await selecting("Debian")
		h.viewModel.treeSelection = [.group("Mounts"), .disk("storage:system")]
		change(h, "Debian") { $0.mounts = [] }
		#expect(await eventually { h.viewModel.treeSelection == [.disk("storage:system")] })
	}

	// Every group by one rule: kept exactly while its section shows unfiltered.
	@Test("T28: a group's selection lasts as long as its section shows")
	func everyGroupFollowsItsSection() {
		let groups = Set(TreeSection.allCases.map { SidebarNode.group($0.title) })
		var vm = Samples.linux()
		#expect(VMListViewModel.liveNodes(groups, in: vm, openSessions: []) == [
			.group("Disks"), .group("Mounts"), .group("Serial"), .group("SSH"),
			.group("Installers"), .group("Devices"),
		])
		vm.disks = []
		vm.mounts = []
		vm.consolePorts = []
		vm.devices = []
		vm.ssh = nil
		vm.boot = Samples.kernelParkedCommandLineOnly().boot
		#expect(VMListViewModel.liveNodes(groups, in: vm, openSessions: []) == [
			.group("Kernel"), .group("Initramfs"),
		])
		#expect(VMListViewModel.liveNodes([.group("Elsewhere")], in: vm, openSessions: [])
			== [.group("Elsewhere")])
	}

	@Test func pruningIgnoresOtherVMs() async {
		let h = await selecting("Debian")
		h.viewModel.treeSelection = [.disk("storage:system"), .serial(
			SerialPortRef(kind: .console, index: 0))]
		change(h, "Alpine") { vm in
			vm.disks.removeAll { $0.id == "storage:system" }
			vm.consolePorts = []
		}
		#expect(await eventually {
			h.viewModel.vms.first { $0.name == "Alpine" }?.consolePorts == []
		})
		#expect(h.viewModel.treeSelection == [
			.disk("storage:system"), .serial(SerialPortRef(kind: .console, index: 0)),
		])
	}
}
