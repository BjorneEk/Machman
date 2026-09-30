import Testing
import Foundation
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
