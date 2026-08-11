import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

// The owned-kernel store: promote copies a file into <vm>/kernels/<name>, it lists and is
// recognized as owned, duplicates and out-of-store deletes are refused, and deleting clears any
// field that referenced it. Pure VMConfig/KernelStore under a redirected data dir.
struct KernelStoreTests {

	@Test func promoteListDeleteClearsReference() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "k")
			let cfg = try VMConfig(name: "k", memorySize: 1 << 30, cpuCount: 2)
			let src = NSTemporaryDirectory() + "ktest-\(UUID().uuidString).bin"
			try Data("KERNEL".utf8).write(to: URL(fileURLWithPath: src))
			defer { try? FileManager.default.removeItem(atPath: src) }

			let dest = try KernelStore.promote(
				sourcePath: src, kernelsDir: cfg.kernelsDirPath(), storeName: "janus")
			#expect(FileManager.default.fileExists(atPath: dest))
			#expect(dest.hasSuffix("/janus/" + (src as NSString).lastPathComponent))
			#expect(cfg.ownedKernelFiles() == [dest])
			#expect(KernelStore.isOwned(dest, kernelsDir: cfg.kernelsDirPath()))

			// Same name+file twice refuses.
			#expect(throws: MachmanError.self) {
				try KernelStore.promote(
					sourcePath: src, kernelsDir: cfg.kernelsDirPath(), storeName: "janus")
			}

			// A kernel field pointing at the owned file is cleared on delete.
			try cfg.updateKernelSettings(LinuxKernelBoot(
				kernelPath: dest, initialRamdiskPath: nil, commandLine: "console=hvc0"))
			try KernelStore.delete(path: dest, kernelsDir: cfg.kernelsDirPath())
			try cfg.clearKernelReference(to: dest)
			#expect(!FileManager.default.fileExists(atPath: dest))
			#expect(cfg.ownedKernelFiles().isEmpty)
			#expect(cfg.kernelSettings?.kernelPath == "")

			// Deleting a path outside the store refuses.
			#expect(throws: MachmanError.self) {
				try KernelStore.delete(path: "/etc/hosts", kernelsDir: cfg.kernelsDirPath())
			}
		}
	}
}
