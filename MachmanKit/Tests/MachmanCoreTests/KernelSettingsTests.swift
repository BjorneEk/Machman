import Testing
import Foundation
import Virtualization
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

struct KernelSettingsTests {

	@Test func legacyConfigWithoutKernelSettingsDecodesToNil() throws {
		let legacy = """
		{
		  "name": "legacy",
		  "memorySize": 4096,
		  "cpuCount": 2,
		  "created": 0
		}
		""".data(using: .utf8)!
		let cfg = try JSONDecoder().decode(VMConfig.self, from: legacy)
		#expect(cfg.kernelSettings == nil)
	}

	@Test func hardwareFloorsOnlyForMacOS() {
		#expect(BootConfig.efi.hardwareFloors == nil)
		let kernel = BootConfig.linuxKernel(
			LinuxKernelBoot(kernelPath: "/k", initialRamdiskPath: nil, commandLine: ""))
		#expect(kernel.hardwareFloors == nil)
		let mac = BootConfig.macOS(
			MacOSBoot(installState: .installed, minimumCPUCount: 4, minimumMemorySize: 8))
		#expect(mac.hardwareFloors?.cpu == 4)
		#expect(mac.hardwareFloors?.mem == 8)
	}

	@Test func kernelBootToggleKeepsDraftAndSwitchesMode() throws {
		try VMTestDir.withRedirectedDir {
			let name = "kernel-vm"
			try VMConfig.createNewVMDirectory(name: name)
			let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			let settings = LinuxKernelBoot(kernelPath: "/vmlinuz",
				initialRamdiskPath: "/initrd", commandLine: "console=hvc0")

			try cfg.setKernelBoot(enabled: true)
			try cfg.updateKernelSettings(settings)
			#expect(cfg.boot == .linuxKernel(settings))
			#expect(cfg.kernelSettings == settings)

			try cfg.setKernelBoot(enabled: false)        // off: draft survives
			#expect(cfg.boot == .efi)
			#expect(cfg.kernelSettings == settings)

			let reloaded = try VMConfig.load(name: name)      // draft survives a reload too
			#expect(reloaded.boot == .efi)
			#expect(reloaded.kernelSettings == settings)

			try reloaded.setKernelBoot(enabled: true)    // re-enabling restores from the draft
			#expect(reloaded.boot == .linuxKernel(settings))
		}
	}

	// C1: a rename moves the directory the owned kernel paths embed — they must follow, in
	// the draft AND the live boot payload, while external paths stay put.
	@Test func renameRepointsOwnedKernelPaths() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "before")
			let cfg = try VMConfig(name: "before", memorySize: 2048, cpuCount: 2)
			let kernelDir = machmanVMDir + "/before/kernels/kernel/v1"
			try FileManager.default.createDirectory(
				atPath: kernelDir, withIntermediateDirectories: true)
			try Data("kern".utf8).write(to: URL(fileURLWithPath: kernelDir + "/vmlinuz"))
			let settings = LinuxKernelBoot(
				kernelPath: kernelDir + "/vmlinuz",
				initialRamdiskPath: "/outside/initrd", commandLine: "console=hvc0")
			try cfg.setKernelBoot(enabled: true)
			try cfg.updateKernelSettings(settings)

			try cfg.rename(to: "after")

			let moved = machmanVMDir + "/after/kernels/kernel/v1/vmlinuz"
			let reloaded = try VMConfig.load(name: "after")
			#expect(reloaded.kernelSettings?.kernelPath == moved)
			#expect(reloaded.kernelSettings?.initialRamdiskPath == "/outside/initrd")
			guard case .linuxKernel(let live) = reloaded.boot else {
				Issue.record("expected a kernel boot")
				return
			}
			#expect(live.kernelPath == moved)
			#expect(FileManager.default.fileExists(atPath: moved))
		}
	}

	// D21: re-tagging the active kernel updated the draft but not the live boot payload, so
	// the next start failed with "Kernel image not found: …/kernel/v1/…"; and the override
	// moved to a key built from the tag trimmed of spaces only, while the file moved to one
	// trimmed of newlines too — orphaning it.
	@Test func retaggingTheActiveKernelKeepsBootOnIt() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "kboot")
			let cfg = try VMConfig(name: "kboot", memorySize: 2048, cpuCount: 2)
			let src = TestEnvironment.scratch + "retag-\(UUID().uuidString).bin"
			try Data("KERNEL".utf8).write(to: URL(fileURLWithPath: src))
			defer { try? FileManager.default.removeItem(atPath: src) }
			let file = (src as NSString).lastPathComponent
			let old = try KernelStore.promote(
				role: .kernel, sourcePath: src, kernelsDir: cfg.kernelsDirPath(), tag: "v1")
			try cfg.setKernelBoot(enabled: true)
			try cfg.updateKernelSettings(LinuxKernelBoot(
				kernelPath: old, initialRamdiskPath: nil, commandLine: "console=hvc0"))
			try cfg.setKernelOverride(forFileAt: old, commandLine: "quiet", enabled: true)

			let new = try cfg.renameKernelFile(path: old, to: "v2\n")

			#expect(new == cfg.kernelsDirPath() + "/kernel/v2/" + file)
			for config in [cfg, try VMConfig.load(name: "kboot")] {
				#expect(config.kernelSettings?.kernelPath == new)
				guard case .linuxKernel(let live) = config.boot else {
					Issue.record("expected a kernel boot")
					return
				}
				#expect(live.kernelPath == new)
				let loader = try config.makeBootLoader() as? VZLinuxBootLoader
				#expect(loader?.kernelURL.path == new)
				#expect(config.kernelOverrides.keys.sorted() == ["kernel/v2/" + file])
			}
		}
	}

	// C11: the kernel-boot toggle can't replace a boot mode a newer Machman wrote — the
	// refusal says why (not the macOS-installed text BootConfigError maps to).
	@Test func aNewerBootModeRefusesTheKernelBootToggle() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "newer")
			let cfg = try VMConfig(name: "newer", memorySize: 2048, cpuCount: 2)
			cfg.boot = try JSONDecoder().decode(
				BootConfig.self, from: Data(#"{"bhyve":{"_0":{"x":1}}}"#.utf8))
			try cfg.saveVMConfig()
			for enabled in [true, false] {
				#expect(throws: MachmanError.self) { try cfg.setKernelBoot(enabled: enabled) }
			}
			#expect(try VMConfig.load(name: "newer").boot == cfg.boot)
			guard case .unknown = cfg.boot else {
				Issue.record("the boot mode was replaced")
				return
			}
		}
	}

	@Test func installedMacOSRefusesKernelBootToggle() throws {
		try VMTestDir.withRedirectedDir {
			let name = "locked-vm"
			try VMConfig.createNewVMDirectory(name: name)
			let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			cfg.boot = .macOS(MacOSBoot(installState: .installed,
				minimumCPUCount: 4, minimumMemorySize: 8))
			#expect(throws: BootConfigError.macOSLocked) {
				try cfg.setKernelBoot(enabled: true)
			}
			#expect(throws: BootConfigError.macOSLocked) {
				try cfg.setKernelBoot(enabled: false)
			}
		}
	}
}
