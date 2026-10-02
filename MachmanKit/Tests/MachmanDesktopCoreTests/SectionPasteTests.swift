//
//  SectionPasteTests.swift
//  MachmanDesktopCoreTests
//
//  Q4: the device tree routed each section's paste (and, apart from that, each section's
//  drop) through its own copy of the same rules. One routing now, AddFlows+Sections: a
//  section takes copied entities of its own kind first, else the pasteboard files that fit
//  it; disk files ask copy-or-reference, folders mount, kernel files promote by their stem.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct SectionPasteTests {
	// One copied entity of every kind, as the clipboard would hold them.
	private let entities = [
		EntityClipboard(kind: .disk, path: "/Users/demo/VMs/a.raw"),
		EntityClipboard(kind: .mount, path: "/Users/demo/notes", tag: "notes"),
		EntityClipboard(kind: .kernel, path: "/Users/demo/k/vmlinuz"),
		EntityClipboard(kind: .initramfs, path: "/Users/demo/k/initrd.img"),
	]

	private let files = [
		URL(fileURLWithPath: "/Users/demo/shared", isDirectory: true),
		URL(fileURLWithPath: "/Users/demo/x.iso"),
		URL(fileURLWithPath: "/Users/demo/disk.qcow2"),
	]

	private func paste(
		_ section: TreeDragPreview.Section, entities: [EntityClipboard] = [],
		files: [URL] = []
	) async -> DesktopHarness {
		let h = await DesktopHarness.make([Samples.linux("Debian")])
		AddFlows.paste(
			into: section, entities: entities, fileURLs: files, vm: "Debian",
			viewModel: h.viewModel, isDirectory: { $0.hasDirectoryPath })
		return h
	}

	private func kernels(_ h: DesktopHarness) -> [OwnedKernelFile] {
		h.stub.vms["Debian"]?.boot.ownedKernels ?? []
	}

	@Test func eachSectionPastesOnlyItsOwnKind() async {
		let disks = await paste(.disks, entities: entities)
		#expect(disks.viewModel.pendingDiskAdd?.urls.map(\.path) == ["/Users/demo/VMs/a.raw"])

		let mounts = await paste(.mounts, entities: entities)
		#expect(await eventually {
			mounts.stub.vms["Debian"]?.mounts.contains { $0.tag == "notes" } == true
		})
		#expect(mounts.viewModel.pendingDiskAdd == nil)
		#expect(!mounts.stub.calls.contains("promoteKernelFile"))

		let kernel = await paste(.kernel(.kernel), entities: entities)
		#expect(await eventually { !kernels(kernel).isEmpty })
		#expect(kernels(kernel).map(\.role) == [.kernel])
		#expect(kernels(kernel).map(\.tag) == ["vmlinuz"])
		#expect(!kernel.stub.calls.contains("addMount"))

		let initramfs = await paste(.kernel(.initramfs), entities: entities)
		#expect(await eventually { !kernels(initramfs).isEmpty })
		#expect(kernels(initramfs).map(\.role) == [.initramfs])
		#expect(kernels(initramfs).map(\.tag) == ["initrd"])
	}

	@Test func withoutEntitiesASectionTakesTheFilesThatFitIt() async {
		let disks = await paste(.disks, files: files)
		#expect(disks.viewModel.pendingDiskAdd?.urls.map(\.path) == ["/Users/demo/x.iso"])
		#expect(!disks.stub.calls.contains("addMount"))

		let mounts = await paste(.mounts, files: files)
		#expect(await eventually {
			mounts.stub.vms["Debian"]?.mounts.contains { $0.tag == "shared" } == true
		})
		#expect(mounts.viewModel.pendingDiskAdd == nil)
	}

	@Test func aDropAddsWhatItCarries() async {
		let h = await DesktopHarness.make([Samples.linux("Debian")])
		AddFlows.add(
			[URL(fileURLWithPath: "/Users/demo/k/vmlinuz-6.13")], to: .kernel(.initramfs),
			vm: "Debian", viewModel: h.viewModel)
		#expect(await eventually { !kernels(h).isEmpty })
		#expect(kernels(h).map(\.role) == [.initramfs])
		#expect(kernels(h).map(\.tag) == ["vmlinuz-6"])
	}

	@Test func eachSectionNamesTheKindItTakes() {
		#expect(EntityClipboard.Kind(section: .disks) == .disk)
		#expect(EntityClipboard.Kind(section: .mounts) == .mount)
		#expect(EntityClipboard.Kind(section: .kernel(.kernel)) == .kernel)
		#expect(EntityClipboard.Kind(section: .kernel(.initramfs)) == .initramfs)
		#expect(EntityClipboard.Kind(section: .kernel(.unknown)) == nil)
	}
}
