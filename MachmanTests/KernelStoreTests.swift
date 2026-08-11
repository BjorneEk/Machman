import Testing
import Foundation
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
			let src = NSTemporaryDirectory() + "ktest-\(UUID().uuidString).bin"
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

			// Deleting a path outside the store refuses.
			#expect(throws: MachmanError.self) {
				try KernelStore.delete(path: "/etc/hosts", kernelsDir: cfg.kernelsDirPath())
			}
		}
	}
}
