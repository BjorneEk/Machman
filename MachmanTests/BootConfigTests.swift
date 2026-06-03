import Testing
import Foundation
@testable import Machman

struct BootConfigTests {

	@Test func bootConfigCasesRoundTrip() throws {
		let cases: [BootConfig] = [
			.efi,
			.linuxKernel(LinuxKernelBoot(kernelPath: "/boot/vmlinuz",
				initialRamdiskPath: "/boot/initrd.img", commandLine: "console=hvc0 root=/dev/vda1 rw")),
			.linuxKernel(LinuxKernelBoot(kernelPath: "/k", initialRamdiskPath: nil, commandLine: "")),
			.macOS(MacOSBoot(installState: .installing, minimumCPUCount: 2, minimumMemorySize: 4_000_000_000)),
			.macOS(MacOSBoot(installState: .installed, minimumCPUCount: 4, minimumMemorySize: 8_000_000_000)),
			.macOS(MacOSBoot(installState: .failed("boom"), minimumCPUCount: 1, minimumMemorySize: 1)),
		]
		for c in cases {
			let data = try JSONEncoder().encode(c)
			let back = try JSONDecoder().decode(BootConfig.self, from: data)
			#expect(back == c)
		}
	}

	// A config written before boot modes existed has no "boot" key; it must load as .efi.
	@Test func legacyConfigWithoutBootDecodesToEFI() throws {
		let legacy = """
		{
		  "name": "legacy",
		  "memorySize": 4096,
		  "cpuCount": 2,
		  "state": "stopped",
		  "created": 0,
		  "mountPoints": [],
		  "disks": []
		}
		""".data(using: .utf8)!
		let cfg = try JSONDecoder().decode(VMConfig.self, from: legacy)
		#expect(cfg.boot == .efi)
	}

	// Exercises the real saveVMConfig() -> init(name:) path (the manual-copy enumeration site).
	@Test func savedBootSurvivesReload() throws {
		try VMTestDir.withRedirectedDir {
			let name = "rt-vm"
			try VMConfig.createNewVMDirectory(name: name)
			let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
			cfg.boot = .linuxKernel(LinuxKernelBoot(kernelPath: "/vmlinuz",
				initialRamdiskPath: nil, commandLine: "console=hvc0 root=/dev/vda1 rw"))
			try cfg.saveVMConfig()

			let reloaded = try VMConfig(name: name)
			#expect(reloaded.boot == cfg.boot)
		}
	}
}
