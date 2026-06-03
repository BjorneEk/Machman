import Testing
import Foundation
@testable import Machman

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

			let reloaded = try VMConfig(name: name)      // draft survives a reload too
			#expect(reloaded.boot == .efi)
			#expect(reloaded.kernelSettings == settings)

			try reloaded.setKernelBoot(enabled: true)    // re-enabling restores from the draft
			#expect(reloaded.boot == .linuxKernel(settings))
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
