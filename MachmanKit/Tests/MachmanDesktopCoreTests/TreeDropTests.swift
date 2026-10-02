import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanDesktopCore

// A drop on a tree section judges every dragged item: the section takes what fits it and the
// preview says how many it skips (P17).
struct TreeDropTests {
	private static func file(_ name: String) -> URL {
		URL(fileURLWithPath: "/Users/demo/Downloads/\(name)", isDirectory: false)
	}
	private static func folder(_ name: String) -> URL {
		URL(fileURLWithPath: "/Users/demo/\(name)", isDirectory: true)
	}
	private static func resolve(_ section: TreeDragPreview.Section, _ urls: [URL])
		-> TreeDragPreview
	{
		TreeDragPreview.resolve(section: section, urls: urls, isDirectory: { $0.hasDirectoryPath })
	}

	@Test func aFolderAmongDiskFilesIsSkipped() {
		let a = Self.file("a.raw"), b = Self.file("b.raw")
		let preview = Self.resolve(.disks, [Self.folder("src"), a, b])
		#expect(preview.verdict == .valid("Add a.raw and 1 more as disks — 1 skipped"))
		#expect(preview.adds == [a, b])
	}

	@Test func aFileAmongFoldersOnMountsIsSkipped() {
		let src = Self.folder("src"), docs = Self.folder("docs")
		let preview = Self.resolve(.mounts, [Self.file("a.raw"), src, docs])
		#expect(preview.verdict == .valid("Share src and 1 more via virtiofs — 1 skipped"))
		#expect(preview.adds == [src, docs])
	}

	@Test func anUnsupportedImageAmongRawsIsSkipped() {
		let a = Self.file("a.raw")
		let preview = Self.resolve(.disks, [a, Self.file("b.qcow2")])
		#expect(preview.verdict == .valid("Add a.raw as a disk — 1 skipped"))
		#expect(preview.adds == [a])
	}

	@Test func aKernelSectionSkipsFolders() {
		let vmlinuz = Self.file("vmlinuz"), image = Self.file("Image")
		let preview = Self.resolve(.kernel(.kernel), [vmlinuz, Self.folder("boot"), image])
		#expect(preview.verdict == .valid("Add vmlinuz and 1 more to Kernel — 1 skipped"))
		#expect(preview.adds == [vmlinuz, image])
	}

	@Test func onlyMisfitsAreRefusedWithTheFirstReason() {
		let disks = Self.resolve(.disks, [Self.file("b.qcow2"), Self.folder("src")])
		#expect(disks.verdict == .invalid(
			"b.qcow2 is not a supported disk format — raw images and ISOs only"))
		#expect(disks.adds.isEmpty)
		let mounts = Self.resolve(.mounts, [Self.file("a.raw")])
		#expect(mounts.verdict == .invalid("Only folders can be shared as mounts"))
		let kernels = Self.resolve(.kernel(.initramfs), [Self.folder("boot")])
		#expect(kernels.verdict == .invalid("Folders can’t be initramfs images"))
	}

	@Test func anUnresolvedPayloadIsLoading() {
		#expect(Self.resolve(.disks, []).verdict == .loading)
	}

	// The default classifier asks the file system, not the URL's trailing slash.
	@Test func theDefaultClassifierReadsTheFileSystem() throws {
		let root = TestEnvironment.scratchURL.appendingPathComponent(UUID().uuidString)
		let dir = root.appendingPathComponent("share")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let image = root.appendingPathComponent("disk.raw")
		try Data([0]).write(to: image)
		let bareDir = URL(fileURLWithPath: dir.path, isDirectory: false)
		let preview = TreeDragPreview.resolve(section: .disks, urls: [bareDir, image])
		#expect(preview.adds == [image])
		#expect(preview.verdict == .valid("Add disk.raw as a disk — 1 skipped"))
	}
}
