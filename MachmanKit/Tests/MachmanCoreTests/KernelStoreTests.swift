import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
@testable import MachmanCore

// The owned-kernel store: promote copies a file into <vm>/kernels/<role>/<tag>, it lists with
// role/tag/fileName, duplicates and out-of-store deletes are refused, and deleting clears any
// field that referenced it. Pure VMConfig/KernelStore under a redirected data dir.
struct KernelStoreTests {

	@Test func promoteListDeleteClearsReference() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "k")
			let cfg = try VMConfig(name: "k", memorySize: 1 << 30, cpuCount: 2)
			let src = TestEnvironment.scratch + "ktest-\(UUID().uuidString).bin"
			try Data("KERNEL".utf8).write(to: URL(fileURLWithPath: src))
			defer { try? FileManager.default.removeItem(atPath: src) }
			let base = (src as NSString).lastPathComponent

			let dest = try KernelStore.promote(
				role: .kernel, sourcePath: src, kernelsDir: cfg.kernelsDirPath(), tag: "janus")
			#expect(FileManager.default.fileExists(atPath: dest))
			#expect(dest.hasSuffix("/kernel/janus/\(base)"))

			let owned = cfg.ownedKernelFiles()
			#expect(owned.count == 1)
			#expect(owned[0].role == .kernel && owned[0].tag == "janus" && owned[0].fileName == base)
			#expect(owned[0].path == dest)
			#expect(KernelStore.isOwned(dest, kernelsDir: cfg.kernelsDirPath()))

			// Same role+tag+file twice refuses.
			#expect(throws: MachmanError.self) {
				try KernelStore.promote(
					role: .kernel, sourcePath: src, kernelsDir: cfg.kernelsDirPath(), tag: "janus")
			}
			// Same file under the initramfs role is a separate owned file.
			let initDest = try KernelStore.promote(
				role: .initramfs, sourcePath: src, kernelsDir: cfg.kernelsDirPath(), tag: "janus")
			#expect(initDest.hasSuffix("/initramfs/janus/\(base)"))
			#expect(cfg.ownedKernelFiles().count == 2)

			// A kernel field pointing at the owned file is cleared on delete.
			try cfg.updateKernelSettings(LinuxKernelBoot(
				kernelPath: dest, initialRamdiskPath: nil, commandLine: "console=hvc0"))
			try KernelStore.delete(path: dest, kernelsDir: cfg.kernelsDirPath())
			try cfg.clearKernelReference(to: dest)
			#expect(!FileManager.default.fileExists(atPath: dest))
			#expect(cfg.kernelSettings?.kernelPath == "")
			#expect(cfg.ownedKernelFiles().map(\.role) == [.initramfs])
			// D10: the emptied tag and role dirs went with the file — but not the kernels
			// dir, which still holds the initramfs file.
			#expect(!FileManager.default.fileExists(
				atPath: cfg.kernelsDirPath() + "/kernel"))
			#expect(FileManager.default.fileExists(atPath: cfg.kernelsDirPath()))

			// Deleting a path outside the store refuses.
			#expect(throws: MachmanError.self) {
				try KernelStore.delete(path: "/etc/hosts", kernelsDir: cfg.kernelsDirPath())
			}

			// D10: the last owned file takes the kernels dir itself with it.
			try KernelStore.delete(path: initDest, kernelsDir: cfg.kernelsDirPath())
			#expect(!FileManager.default.fileExists(atPath: cfg.kernelsDirPath()))
		}
	}

	// Files copied in by an older build live at <kernels>/<storeName>/<file> (no role level).
	// They must still surface, with role from the config's references, else inferred by name.
	// D16: ownership was a raw string prefix, so "<kernels>/../disk.raw" passed and
	// vm.kernel.delete removed a VM file. Paths are resolved before the check, and a
	// directory is never "an owned file".
	// D30 (review 4): the scan listed every entry of a tag dir, so Finder's .DS_Store became an
	// owned "kernel" that kept the Kernel section after the real one was deleted, and a
	// folder became a row that delete refuses.
	@Test("D30: Finder's .DS_Store and a stray folder in the kernels store are not kernel files")
	func finderLeftoversAreNotKernelFiles() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "finder")
			let cfg = try VMConfig(name: "finder", memorySize: 1 << 30, cpuCount: 2)
			let kernelsDir = cfg.kernelsDirPath()
			let src = TestEnvironment.scratch + "d30-\(UUID().uuidString)"
			try Data("KERNEL".utf8).write(to: URL(fileURLWithPath: src))
			defer { try? FileManager.default.removeItem(atPath: src) }
			let kernel = try KernelStore.promote(
				role: .kernel, sourcePath: src, kernelsDir: kernelsDir, tag: "v1")
			let fm = FileManager.default
			let tagDir = (kernel as NSString).deletingLastPathComponent
			let ds = Data([0, 0, 0, 1])
			for dir in [tagDir, kernelsDir + "/kernel", kernelsDir] {
				try ds.write(to: URL(fileURLWithPath: dir + "/.DS_Store"))
			}
			try fm.createDirectory(
				atPath: kernelsDir + "/kernel/v2/stray", withIntermediateDirectories: true)
			try fm.createDirectory(
				atPath: kernelsDir + "/legacy", withIntermediateDirectories: true)
			try ds.write(to: URL(fileURLWithPath: kernelsDir + "/legacy/.DS_Store"))

			#expect(cfg.ownedKernelFiles().map(\.path) == [kernel])
			try KernelStore.delete(path: kernel, kernelsDir: kernelsDir)
			#expect(cfg.ownedKernelFiles().isEmpty)
			#expect(!fm.fileExists(atPath: tagDir))   // its .DS_Store didn't keep it
			// The user's own folder stays.
			#expect(fm.fileExists(atPath: kernelsDir + "/kernel/v2/stray"))
		}
	}

	@Test func deleteRefusesPathsThatClimbOutOfTheStore() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "k")
			let cfg = try VMConfig(name: "k", memorySize: 1 << 30, cpuCount: 2)
			let src = TestEnvironment.scratch + "ktest-\(UUID().uuidString).bin"
			try Data("KERNEL".utf8).write(to: URL(fileURLWithPath: src))
			defer { try? FileManager.default.removeItem(atPath: src) }
			let dest = try KernelStore.promote(
				role: .kernel, sourcePath: src, kernelsDir: cfg.kernelsDirPath(), tag: "janus")
			let disk = cfg.configFilePath(file: "disk.raw")
			try Data("DISK".utf8).write(to: URL(fileURLWithPath: disk))

			#expect(!KernelStore.isOwned(
				cfg.kernelsDirPath() + "/../disk.raw", kernelsDir: cfg.kernelsDirPath()))
			#expect(throws: MachmanError.self) {
				try KernelStore.delete(
					path: cfg.kernelsDirPath() + "/../disk.raw", kernelsDir: cfg.kernelsDirPath())
			}
			#expect(FileManager.default.fileExists(atPath: disk))
			#expect(throws: MachmanError.self) {
				try KernelStore.rename(
					path: cfg.kernelsDirPath() + "/kernel/janus/../../../disk.raw",
					kernelsDir: cfg.kernelsDirPath(), newTag: "x")
			}
			#expect(FileManager.default.fileExists(atPath: disk))
			#expect(FileManager.default.fileExists(atPath: dest))
		}
	}

	@Test func deleteRefusesDirectories() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "k")
			let cfg = try VMConfig(name: "k", memorySize: 1 << 30, cpuCount: 2)
			let src = TestEnvironment.scratch + "ktest-\(UUID().uuidString).bin"
			try Data("KERNEL".utf8).write(to: URL(fileURLWithPath: src))
			defer { try? FileManager.default.removeItem(atPath: src) }
			let dest = try KernelStore.promote(
				role: .kernel, sourcePath: src, kernelsDir: cfg.kernelsDirPath(), tag: "janus")
			#expect(throws: MachmanError.self) {
				try KernelStore.delete(
					path: cfg.kernelsDirPath() + "/kernel", kernelsDir: cfg.kernelsDirPath())
			}
			#expect(FileManager.default.fileExists(atPath: dest))
		}
	}

	@Test func tagsFollowTheNameRule() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "k")
			let cfg = try VMConfig(name: "k", memorySize: 1 << 30, cpuCount: 2)
			let src = TestEnvironment.scratch + "ktest-\(UUID().uuidString).bin"
			try Data("KERNEL".utf8).write(to: URL(fileURLWithPath: src))
			defer { try? FileManager.default.removeItem(atPath: src) }
			for bad in ["..", ".x", "a\tb", "a/b", " "] {
				#expect(throws: MachmanError.self, "\(bad)") {
					try KernelStore.promote(
						role: .kernel, sourcePath: src, kernelsDir: cfg.kernelsDirPath(),
						tag: bad)
				}
			}
			#expect(!FileManager.default.fileExists(atPath: cfg.kernelsDirPath() + "/kernel/.."
				+ "/" + (src as NSString).lastPathComponent))
			let dest = try KernelStore.promote(
				role: .kernel, sourcePath: src, kernelsDir: cfg.kernelsDirPath(), tag: " 6.12 ")
			#expect(dest.contains("/kernel/6.12/"))
			#expect(throws: MachmanError.self) {
				try KernelStore.rename(path: dest, kernelsDir: cfg.kernelsDirPath(), newTag: "..")
			}
		}
	}

	@Test func legacyFlatLayoutFilesAreSurfaced() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "j")
			let cfg = try VMConfig(name: "j", memorySize: 1 << 30, cpuCount: 2)
			let fm = FileManager.default
			let legacyDir = cfg.kernelsDirPath() + "/janusrt"
			try fm.createDirectory(atPath: legacyDir, withIntermediateDirectories: true)
			let kpath = legacyDir + "/Image"
			try Data("K".utf8).write(to: URL(fileURLWithPath: kpath))
			try Data("I".utf8).write(to: URL(fileURLWithPath: legacyDir + "/initramfs.cpio"))
			try Data("X".utf8).write(to: URL(fileURLWithPath: legacyDir + "/vmlinuz-extra"))

			// Config points at Image as the kernel; the other two are unreferenced.
			try cfg.updateKernelSettings(LinuxKernelBoot(
				kernelPath: kpath, initialRamdiskPath: nil, commandLine: ""))

			let owned = cfg.ownedKernelFiles()
			#expect(owned.count == 3)
			let byName = Dictionary(uniqueKeysWithValues: owned.map { ($0.fileName, $0) })
			#expect(byName["Image"]?.role == .kernel)              // from the config reference
			#expect(byName["initramfs.cpio"]?.role == .initramfs)  // name-inferred
			#expect(byName["vmlinuz-extra"]?.role == .kernel)      // name-inferred default
			#expect(owned.allSatisfy { $0.tag == "janusrt" })
		}
	}

	// A current-layout owned file and a legacy flat file are both listed.
	@Test func legacyAndCurrentLayoutsCoexist() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "j2")
			let cfg = try VMConfig(name: "j2", memorySize: 1 << 30, cpuCount: 2)
			let fm = FileManager.default
			let src = TestEnvironment.scratch + "k-\(UUID().uuidString).bin"
			try Data("K".utf8).write(to: URL(fileURLWithPath: src))
			defer { try? fm.removeItem(atPath: src) }
			_ = try KernelStore.promote(
				role: .kernel, sourcePath: src, kernelsDir: cfg.kernelsDirPath(), tag: "new")
			let legacyDir = cfg.kernelsDirPath() + "/old"
			try fm.createDirectory(atPath: legacyDir, withIntermediateDirectories: true)
			try Data("L".utf8).write(to: URL(fileURLWithPath: legacyDir + "/vmlinuz"))

			#expect(Set(cfg.ownedKernelFiles().map(\.tag)) == ["new", "old"])
		}
	}

	// D35 (review 4): two Debian kernels landed under one tag — only an identical file name was
	// refused — and the tree drew two identical rows that the Tag field treated as one. K13: a
	// tag names one kernel file, and a second is refused, saying why.
	@Test("D35: a second kernel file into a tag that holds one is refused with a reason")
	func aTakenTagRefusesASecondFile() throws {
		let dir = TestEnvironment.scratch + "d35-\(UUID().uuidString)"
		let kernels = dir + "/kernels"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let first = dir + "/vmlinuz-6.1.0-18-arm64"
		let second = dir + "/vmlinuz-6.1.0-21-arm64"
		for file in [first, second] {
			try Data("kernel".utf8).write(to: URL(fileURLWithPath: file))
		}
		_ = try KernelStore.promote(
			role: .kernel, sourcePath: first, kernelsDir: kernels, tag: "vmlinuz-6.1")
		let error = try #require(throws: MachmanError.self) {
			try KernelStore.promote(
				role: .kernel, sourcePath: second, kernelsDir: kernels, tag: "vmlinuz-6.1")
		}
		#expect(error.code == .alreadyExists)
		#expect(error.message == "\u{201C}vmlinuz-6.1\u{201D} already holds a kernel file")
		#expect(KernelStore.ownedFiles(kernelsDir: kernels).map(\.fileName)
			== ["vmlinuz-6.1.0-18-arm64"])
		// The initramfs role's tag of the same name is a tag of its own.
		_ = try KernelStore.promote(
			role: .initramfs, sourcePath: second, kernelsDir: kernels, tag: "vmlinuz-6.1")
	}

	// D39 (review 4): a kernel import copied straight to <role>/<tag>/<file>, so a crash, a kill
	// or a full disk mid-copy left a truncated file the VM listed as its own kernel. The copy
	// is staged now, and the tag dir appears only once it is whole.
	private struct Interrupted: Error {}

	private func storeDir() throws -> (dir: String, kernels: String, source: String) {
		let dir = TestEnvironment.scratch + "d39-\(UUID().uuidString)"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		let source = dir + "-vmlinuz"
		try Data(repeating: 0x4B, count: 64 << 10).write(to: URL(fileURLWithPath: source))
		return (dir, dir + "/kernels", source)
	}

	private func staging(in dir: String) -> [String] {
		((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
			.filter { $0.hasPrefix(DiskImport.stagingPrefix) }
	}

	@Test("D39: a kernel import that fails mid-copy leaves nothing under its tag")
	func aFailedCopyLeavesNoFile() throws {
		let (dir, kernels, source) = try storeDir()
		defer {
			try? FileManager.default.removeItem(atPath: dir)
			try? FileManager.default.removeItem(atPath: source)
		}
		#expect(throws: Interrupted.self) {
			try KernelStore.promote(
				role: .kernel, sourcePath: source, kernelsDir: kernels, tag: "v1"
			) { _, staged in
				try Data(count: 4096).write(to: URL(fileURLWithPath: staged))
				throw Interrupted()
			}
		}
		#expect(!FileManager.default.fileExists(atPath: kernels + "/kernel/v1"))
		#expect(KernelStore.ownedFiles(kernelsDir: kernels).isEmpty)
		#expect(staging(in: dir).isEmpty)
		let dest = try KernelStore.promote(
			role: .kernel, sourcePath: source, kernelsDir: kernels, tag: "v1")
		#expect(try Data(contentsOf: URL(fileURLWithPath: dest))
			== Data(contentsOf: URL(fileURLWithPath: source)))
	}

	// A crash mid-copy leaves the staged folder: it sits where the daemon's startup sweep of
	// the VM folder removes it (the sweep run from inside the copy stands in for the restart).
	@Test("D39: an interrupted kernel import's staging goes with the startup sweep")
	func theSweepTakesAnInterruptedImport() throws {
		let (dir, kernels, source) = try storeDir()
		defer {
			try? FileManager.default.removeItem(atPath: dir)
			try? FileManager.default.removeItem(atPath: source)
		}
		var swept: [String]?
		#expect(throws: Interrupted.self) {
			try KernelStore.promote(
				role: .kernel, sourcePath: source, kernelsDir: kernels, tag: "v1"
			) { _, staged in
				try Data(count: 4096).write(to: URL(fileURLWithPath: staged))
				let before = staging(in: dir)
				DiskImport.sweepStaleStaging(vmDir: dir)
				swept = before.filter { !staging(in: dir).contains($0) }
				throw Interrupted()
			}
		}
		#expect(swept?.count == 1)
		#expect(KernelStore.ownedFiles(kernelsDir: kernels).isEmpty)
	}

	// D40's mode rule for kernel files: like a disk import's file, a promoted kernel is
	// owner-only, and so is the tag dir it lands in (K5: new files only).
	@Test("D39: a promoted kernel file and its tag dir are owner-only")
	func aPromotedKernelIsOwnerOnly() throws {
		let (dir, kernels, source) = try storeDir()
		defer {
			try? FileManager.default.removeItem(atPath: dir)
			try? FileManager.default.removeItem(atPath: source)
		}
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o644], ofItemAtPath: source)
		let dest = try KernelStore.promote(
			role: .kernel, sourcePath: source, kernelsDir: kernels, tag: "v1")
		func mode(_ path: String) throws -> Int? {
			try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
		}
		#expect(try mode(dest) == 0o600)
		#expect(try mode(kernels + "/kernel/v1") == 0o700)
	}

	// Kernel-import claims don't exclude each other: an import that lands first takes the tag,
	// and the one placed after it is refused (K13), leaving nothing behind. A tag dir left
	// holding only Finder's .DS_Store is no kernel file and is taken.
	@Test("D39: two imports placed into one tag land one file")
	func twoImportsIntoOneTagLandOne() throws {
		let (dir, kernels, source) = try storeDir()
		defer {
			try? FileManager.default.removeItem(atPath: dir)
			try? FileManager.default.removeItem(atPath: source)
		}
		try FileManager.default.createDirectory(
			atPath: kernels + "/kernel/v1", withIntermediateDirectories: true)
		try Data().write(to: URL(fileURLWithPath: kernels + "/kernel/v1/.DS_Store"))
		let other = dir + "/Image"
		try Data("other".utf8).write(to: URL(fileURLWithPath: other))
		var landed: String?
		let error = try #require(throws: MachmanError.self) {
			try KernelStore.promote(
				role: .kernel, sourcePath: source, kernelsDir: kernels, tag: "v1"
			) { src, staged in
				try FileManager.default.copyItem(atPath: src, toPath: staged)
				landed = try KernelStore.promote(
					role: .kernel, sourcePath: other, kernelsDir: kernels, tag: "v1")
			}
		}
		#expect(error.message == "\u{201C}v1\u{201D} already holds a kernel file")
		#expect(landed == kernels + "/kernel/v1/Image")
		#expect(KernelStore.ownedFiles(kernelsDir: kernels).map(\.fileName) == ["Image"])
		#expect(staging(in: dir).isEmpty)
	}

	// D35 by the rename path: a re-tag into a tag that held another file put two kernels under
	// one tag the same way an import did. Refused with the same sentence; a file of the other
	// role under that tag doesn't count, and neither does another VM's (tags are per VM).
	@Test("D35: re-tagging into a tag that holds another kernel file is refused")
	func aRetagIntoATakenTagIsRefused() throws {
		let dir = TestEnvironment.scratch + "d35r-\(UUID().uuidString)"
		let kernels = dir + "/kernels"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let first = dir + "/vmlinuz"
		let second = dir + "/Image"
		for file in [first, second] {
			try Data("kernel".utf8).write(to: URL(fileURLWithPath: file))
		}
		let stable = try KernelStore.promote(
			role: .kernel, sourcePath: first, kernelsDir: kernels, tag: "stable")
		let next = try KernelStore.promote(
			role: .kernel, sourcePath: second, kernelsDir: kernels, tag: "next")
		_ = try KernelStore.promote(
			role: .initramfs, sourcePath: second, kernelsDir: kernels, tag: "lts")
		let error = try #require(throws: MachmanError.self) {
			_ = try KernelStore.rename(path: next, kernelsDir: kernels, newTag: "stable")
		}
		#expect(error.message == "\u{201C}stable\u{201D} already holds a kernel file")
		#expect(FileManager.default.fileExists(atPath: next))
		#expect(try KernelStore.rename(path: stable, kernelsDir: kernels, newTag: "lts")
			== kernels + "/kernel/lts/vmlinuz")
		// Tags are per VM: another VM's kernel takes a tag this one holds ("next").
		let otherKernels = dir + "/other-vm/kernels"
		let other = try KernelStore.promote(
			role: .kernel, sourcePath: first, kernelsDir: otherKernels, tag: "6.12")
		#expect(try KernelStore.rename(path: other, kernelsDir: otherKernels, newTag: "next")
			== otherKernels + "/kernel/next/vmlinuz")
	}

	// F22: only a tag dir holding exactly Finder's .DS_Store was cleared; any other hidden
	// leftover beside it (a FUSE mount's .fuse_hidden file; AppleDouble "._" files never list)
	// kept the dir, and the import was refused with "“v1” already holds a kernel file" for a
	// tag the tree lists nothing under. Any dir left with only hidden files is cleared now — at
	// an import's placement and a delete's walk-up.
	@Test("F22: a tag dir left with only hidden files takes the import and goes with a delete")
	func hiddenLeftoversNeverHoldATag() throws {
		let (dir, kernels, source) = try storeDir()
		defer {
			try? FileManager.default.removeItem(atPath: dir)
			try? FileManager.default.removeItem(atPath: source)
		}
		let tagDir = kernels + "/kernel/v1"
		try FileManager.default.createDirectory(atPath: tagDir, withIntermediateDirectories: true)
		let fuse = ".fuse_hidden0000000a00000001"
		for junk in [".DS_Store", "._.DS_Store", fuse] {
			try Data("x".utf8).write(to: URL(fileURLWithPath: tagDir + "/" + junk))
		}
		let dest = try KernelStore.promote(
			role: .kernel, sourcePath: source, kernelsDir: kernels, tag: "v1")
		#expect(KernelStore.ownedFiles(kernelsDir: kernels).map(\.path) == [dest])

		// Leftovers beside the last file don't keep the emptied tag, role and kernels dirs.
		for junk in [fuse, "._" + (dest as NSString).lastPathComponent] {
			try Data("x".utf8).write(to: URL(fileURLWithPath: tagDir + "/" + junk))
		}
		try KernelStore.delete(path: dest, kernelsDir: kernels)
		#expect(!FileManager.default.fileExists(atPath: kernels))

		// A hidden folder is not a leftover: the tag stays taken by it, untouched.
		try FileManager.default.createDirectory(
			atPath: tagDir + "/.keep", withIntermediateDirectories: true)
		#expect(throws: MachmanError.self) {
			try KernelStore.promote(
				role: .kernel, sourcePath: source, kernelsDir: kernels, tag: "v1")
		}
		#expect(FileManager.default.fileExists(atPath: tagDir + "/.keep"))
	}
}
