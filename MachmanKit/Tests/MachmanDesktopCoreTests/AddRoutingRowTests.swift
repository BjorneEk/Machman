//
//  AddRoutingRowTests.swift
//  MachmanDesktopCoreTests
//
//  The manual rows of the add routing, on the view model (P17, H25): a browsed disk file
//  asks copy or reference before anything is added (17b), disk files dropped on Disks
//  share one question (20b), a folder in such a drop is skipped (W1-13), two copied disks
//  pasted by Reference add under one toast (W1-15), Copy Items then Paste Items into
//  another VM asks the same question (W0-2a), and Paste is offered only where the
//  pasteboard's files fit (W3-53). The panels, the drop delegate and the pasteboard are
//  AppKit; each hands this routing its URLs or entities, which is what runs here.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// L1: view model (DesktopHarness + StubMachman).
@MainActor
struct AddRoutingRowTests {
	// Real files in a fresh scratch folder: the routing asks the file system what they are.
	private static func files(_ names: [String]) throws -> [URL] {
		let dir = try folder()
		return try names.map { name in
			let url = dir.appendingPathComponent(name)
			try Data([0]).write(to: url)
			return url
		}
	}

	private static func folder() throws -> URL {
		let dir = TestEnvironment.scratchURL.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	private func count(_ method: String, in h: DesktopHarness) -> Int {
		h.stub.calls.filter { $0 == method }.count
	}

	private func addsNothing(_ h: DesktopHarness) -> Bool {
		!h.stub.calls.contains("importDisk") && !h.stub.calls.contains("addDisk")
			&& !h.stub.calls.contains("addMount")
	}

	// MARK: - 17b

	@Test("17b: a browsed disk file asks copy or reference before anything is added")
	func aBrowsedFileAsksFirst() async throws {
		let h = await DesktopHarness.make()
		let file = try Self.files(["debian.img"])[0]
		// What chooseExistingDisk does with the panel's answer.
		AddFlows.askDiskReferenceOrCopy(viewModel: h.viewModel, vm: "Alpine", url: file)
		let pending = try #require(h.viewModel.pendingDiskAdd)
		#expect(pending.vm == "Alpine")
		#expect(pending.urls == [file])
		#expect(pending.title == "Add \u{201C}debian.img\u{201D}?")
		#expect(h.viewModel.isDiskAddPresented)
		try? await Task.sleep(for: .milliseconds(50))
		#expect(addsNothing(h), "\(h.stub.calls)")
	}

	@Test("17b: Copy imports the browsed file and Reference adds it as an image")
	func copyImportsAndReferenceAdds() async throws {
		let h = await DesktopHarness.make()
		let file = try Self.files(["debian.img"])[0]
		AddFlows.askDiskReferenceOrCopy(viewModel: h.viewModel, vm: "Alpine", url: file)
		let copy = try #require(h.viewModel.pendingDiskAdd)
		AddFlows.addDiskCopies(viewModel: h.viewModel, copy)
		#expect(await eventually { count("importDisk", in: h) == 1 })
		#expect(h.stub.vms["Alpine"]?.disks.last?.path == file.path)
		#expect(h.stub.addedDisks.isEmpty)

		h.viewModel.isDiskAddPresented = false
		AddFlows.askDiskReferenceOrCopy(viewModel: h.viewModel, vm: "Alpine", url: file)
		let reference = try #require(await pending(in: h, other: copy.id))
		AddFlows.addDiskReferences(viewModel: h.viewModel, reference)
		#expect(await eventually { h.stub.addedDisks.count == 1 })
		#expect(h.stub.addedDisks.first?.vm == "Alpine")
		#expect(h.stub.addedDisks.first?.disk == .image(path: file.path))
		#expect(count("importDisk", in: h) == 1)
	}

	// The question after `other`, once the queue has moved on to it.
	private func pending(in h: DesktopHarness, other: UUID) async
		-> VMListViewModel.PendingDiskAdd? {
		_ = await eventually {
			h.viewModel.pendingDiskAdd != nil && h.viewModel.pendingDiskAdd?.id != other
		}
		return h.viewModel.pendingDiskAdd
	}

	// MARK: - Drops

	@Test("20b: disk files dropped on Disks share one question and Copy imports each")
	func diskFilesShareOneQuestion() async throws {
		let h = await DesktopHarness.make()
		let files = try Self.files(["a.raw", "b.img"])
		let preview = TreeDragPreview.resolve(section: .disks, urls: files)
		#expect(preview.verdict == .valid("Add a.raw and 1 more as disks"))
		#expect(preview.adds == files)
		// TreeContext.drop's one line for a valid drop.
		AddFlows.add(preview.adds, to: .disks, vm: "Alpine", viewModel: h.viewModel)
		let pending = try #require(h.viewModel.pendingDiskAdd)
		#expect(pending.urls == files)
		#expect(pending.title == "Copy or reference these 2 files?")
		AddFlows.addDiskCopies(viewModel: h.viewModel, pending)
		#expect(await eventually { count("importDisk", in: h) == 2 })
		h.viewModel.isDiskAddPresented = false
		#expect(await eventually { h.viewModel.pendingDiskAdd == nil })
	}

	@Test("W1-13: a folder and an image on Disks add only the image, one skipped")
	func aFolderAndAnImageAddOnlyTheImage() async throws {
		let h = await DesktopHarness.make()
		let dir = try Self.folder()
		let image = try Self.files(["x.img"])[0]
		let preview = TreeDragPreview.resolve(section: .disks, urls: [dir, image])
		#expect(preview.verdict == .valid("Add x.img as a disk \u{2014} 1 skipped"))
		#expect(preview.adds == [image])
		AddFlows.add(preview.adds, to: .disks, vm: "Alpine", viewModel: h.viewModel)
		#expect(h.viewModel.pendingDiskAdd?.urls == [image])
		try? await Task.sleep(for: .milliseconds(50))
		#expect(!h.stub.calls.contains("addMount"), "\(h.stub.calls)")
	}

	// MARK: - Paste

	@Test("W1-15: two copied disks pasted by Reference add both under one toast")
	func twoPastedDisksShareOneToast() async throws {
		let h = await DesktopHarness.make()
		let entities = [
			EntityClipboard(kind: .disk, path: "/Users/demo/VMs/a.raw"),
			EntityClipboard(kind: .disk, path: "/Users/demo/VMs/b.raw"),
		]
		AddFlows.paste(entities: entities, fileURLs: [], into: "Alpine", viewModel: h.viewModel)
		let pending = try #require(h.viewModel.pendingDiskAdd)
		#expect(pending.urls.count == 2)
		AddFlows.addDiskReferences(viewModel: h.viewModel, pending)
		#expect(await eventually { h.stub.addedDisks.count == 2 })
		#expect(await eventually {
			h.viewModel.toasts.contains { $0.message == "Added 2 disks" }
		})
		#expect(h.viewModel.toasts.filter { $0.message.hasPrefix("Added") }.count == 1)
		#expect(!h.viewModel.toasts.contains { $0.message == "Added disk" })
	}

	@Test("W0-2a: Copy Items then Paste Items into another VM asks copy or reference")
	func copyItemsThenPasteAsks() async throws {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		h.viewModel.treeSelection = [.disk("storage:system")]
		// Copy Items reads the key window's target; Paste Items hands it to the routing.
		let copied = CommandTarget(viewModel: h.viewModel, window: .main).copyableItems
		let system = "\(Samples.vmsRoot)/Debian/system.raw"
		#expect(copied.map(\.path) == [system])
		#expect(copied.map(\.kind) == [.disk])
		AddFlows.paste(entities: copied, fileURLs: [], into: "Alpine", viewModel: h.viewModel)
		let pending = try #require(h.viewModel.pendingDiskAdd)
		#expect(pending.vm == "Alpine")
		#expect(pending.urls.map(\.path) == [system])
		#expect(pending.title == "Add \u{201C}system.raw\u{201D}?")
	}

	@Test("W3-53: a copied disk image enables Paste on Disks only; a folder on Mounts only")
	func pasteFollowsWhatThePasteboardHolds() throws {
		let image = try Self.files(["disk.img"])[0]
		let disk = PasteboardSnapshot(entities: [], fileURLs: [image])
		#expect(disk.canPaste(into: .disks))
		#expect(!disk.canPaste(into: .mounts))

		let folder = PasteboardSnapshot(entities: [], fileURLs: [try Self.folder()])
		#expect(folder.canPaste(into: .mounts))
		#expect(!folder.canPaste(into: .disks))

		#expect(!PasteboardSnapshot.empty.canPaste(into: .disks))
		#expect(!PasteboardSnapshot.empty.canPaste(into: .mounts))
	}
}
