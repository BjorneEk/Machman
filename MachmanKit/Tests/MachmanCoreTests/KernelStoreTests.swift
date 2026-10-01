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
}
