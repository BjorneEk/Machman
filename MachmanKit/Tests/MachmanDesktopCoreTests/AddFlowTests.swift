import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// Dropped/pasted files: disk files queue ONE copy-or-reference question per gesture, applied
// to all of them; folders mount (P17).
@MainActor
struct AddFlowTests {
	// Real files in a fresh scratch folder (the drop routing asks the file system).
	private static func files(_ names: [String]) throws -> [URL] {
		let dir = TestEnvironment.scratchURL.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

	@Test func aDiskFileQueuesTheQuestionAndReferenceAddsIt() async throws {
		let h = await DesktopHarness.make()
		let file = try Self.files(["\(UUID()).iso"])[0]
		#expect(AddFlows.handleFileURLs([file], viewModel: h.viewModel, vm: "Debian"))
		#expect(await eventually { h.viewModel.pendingDiskAdd != nil })   // judged off main (P45)
		let pending = try #require(h.viewModel.pendingDiskAdd)
		#expect(pending.urls == [file])
		#expect(pending.title == "Add \u{201C}\(file.lastPathComponent)\u{201D}?")
		AddFlows.addDiskReferences(viewModel: h.viewModel, pending)
		#expect(await eventually { h.stub.addedDisks.count == 1 })
		#expect(h.stub.addedDisks.first?.disk == .iso(path: file.path))
	}

	@Test func aFolderBecomesAMount() async throws {
		let h = await DesktopHarness.make()
		let dir = try Self.folder()
		#expect(AddFlows.handleFileURLs([dir], viewModel: h.viewModel, vm: "Debian"))
		#expect(await eventually { h.stub.calls.contains("addMount") })
		#expect(h.viewModel.pendingDiskAdd == nil)
	}

	@Test func threeDroppedFilesAskOnceAndCopyAll() async throws {
		let h = await DesktopHarness.make()
		let files = try Self.files(["a.raw", "b.raw", "c.iso"])
		#expect(AddFlows.handleFileURLs(files, viewModel: h.viewModel, vm: "Debian"))
		#expect(await eventually { h.viewModel.pendingDiskAdd != nil })
		let pending = try #require(h.viewModel.pendingDiskAdd)
		#expect(pending.urls == files)
		#expect(pending.title == "Copy or reference these 3 files?")
		#expect(pending.message
			== "Copies travel with Debian, and references use the originals in place.")
		AddFlows.addDiskCopies(viewModel: h.viewModel, pending)
		#expect(await eventually { count("importDisk", in: h) == 3 })
		let imported = h.stub.vms["Debian"]?.disks.filter { $0.id == "storage:imported" }
		#expect(imported?.map(\.path) == files.map(\.path))
	}

	@Test func referenceAppliesToEveryFile() async throws {
		let h = await DesktopHarness.make()
		let files = try Self.files(["a.raw", "b.raw", "c.iso"])
		_ = AddFlows.handleFileURLs(files, viewModel: h.viewModel, vm: "Debian")
		#expect(await eventually { h.viewModel.pendingDiskAdd != nil })
		let pending = try #require(h.viewModel.pendingDiskAdd)
		AddFlows.addDiskReferences(viewModel: h.viewModel, pending)
		#expect(await eventually { h.stub.addedDisks.count == 3 })
		#expect(h.stub.addedDisks.map(\.disk) == [
			.image(path: files[0].path), .image(path: files[1].path), .iso(path: files[2].path),
		])
		#expect(await eventually { h.viewModel.toasts.contains { $0.message == "Added 3 disks" } })
		#expect(!h.viewModel.toasts.contains { $0.message == "Added disk" })
	}

	@Test func aMixedDropMountsTheFolderAndAsksOnce() async throws {
		let h = await DesktopHarness.make()
		let dir = try Self.folder()
		let files = try Self.files(["a.raw", "b.raw"])
		_ = AddFlows.handleFileURLs([dir] + files, viewModel: h.viewModel, vm: "Debian")
		#expect(await eventually { h.stub.calls.contains("addMount") })
		#expect(h.viewModel.pendingDiskAdd?.urls == files)
	}

	@Test func aSecondBatchWaitsForTheFirstAnswer() async throws {
		let h = await DesktopHarness.make()
		let a = URL(fileURLWithPath: "/Users/demo/a.raw")
		let b = URL(fileURLWithPath: "/Users/demo/b.raw")
		AddFlows.askDiskReferenceOrCopy(viewModel: h.viewModel, vm: "Debian", urls: [a])
		AddFlows.askDiskReferenceOrCopy(viewModel: h.viewModel, vm: "Debian", urls: [b])
		#expect(h.viewModel.pendingDiskAdd?.urls == [a])
		h.viewModel.isDiskAddPresented = false
		#expect(await eventually { h.viewModel.pendingDiskAdd?.urls == [b] })
		h.viewModel.isDiskAddPresented = false
		#expect(await eventually { h.viewModel.pendingDiskAdd == nil })
	}

	@Test func pastingTwoCopiedDisksAsksOnce() async throws {
		let h = await DesktopHarness.make()
		let entities = [
			EntityClipboard(kind: .disk, path: "/Users/demo/VMs/a.raw"),
			EntityClipboard(kind: .disk, path: "/Users/demo/VMs/b.raw"),
			EntityClipboard(kind: .mount, path: "/Users/demo/src", tag: "src"),
		]
		AddFlows.paste(entities: entities, fileURLs: [], into: "Alpine", viewModel: h.viewModel)
		let pending = try #require(h.viewModel.pendingDiskAdd)
		#expect(pending.vm == "Alpine")
		#expect(pending.urls.map(\.path) == ["/Users/demo/VMs/a.raw", "/Users/demo/VMs/b.raw"])
		#expect(await eventually { h.stub.calls.contains("addMount") })
	}

	@Test func aFailedCopyDoesNotStopTheRest() async throws {
		let h = await DesktopHarness.make()
		h.stub.fail("importDisk", with: MachmanError(code: .ioFailure, message: "disk full"))
		h.viewModel.importDisks("Debian", paths: ["/x/a.raw", "/x/b.raw", "/x/c.raw"])
		#expect(await eventually { count("importDisk", in: h) == 3 })
		#expect(h.viewModel.presentedError?.title
			== "Importing \u{201C}a.raw\u{201D} into \u{201C}Debian\u{201D} failed")
		#expect(h.viewModel.presentedError?.message == "disk full")
	}

	// D35: a kernel added under a tag that already holds one is refused (K13), and the add
	// that asked says why: the drop's alert carries the agent's sentence.
	@Test("D35: adding a kernel under a taken tag says why where it was added")
	func aTakenKernelTagSaysWhy() async throws {
		let h = await DesktopHarness.make([Samples.linux("Debian")])
		let first = URL(fileURLWithPath: "/Users/demo/Downloads/vmlinuz")
		AddFlows.add([first], to: .kernel(.kernel), vm: "Debian", viewModel: h.viewModel)
		#expect(await eventually {
			h.stub.vms["Debian"]?.boot.ownedKernels?.map(\.tag) == ["vmlinuz"]
		})
		let second = URL(fileURLWithPath: "/Users/demo/build/vmlinuz")
		AddFlows.add([second], to: .kernel(.kernel), vm: "Debian", viewModel: h.viewModel)
		#expect(await eventually { h.viewModel.presentedError != nil })
		#expect(h.viewModel.presentedError?.title == "Promoting a kernel file failed")
		#expect(h.viewModel.presentedError?.message
			== "\u{201C}vmlinuz\u{201D} already holds a kernel file")
		#expect(h.stub.vms["Debian"]?.boot.ownedKernels?.count == 1)
	}
}
