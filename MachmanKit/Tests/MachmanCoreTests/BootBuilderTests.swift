import Testing
import Foundation
import Virtualization
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

struct BootBuilderTests {

	private func kernel() -> BootConfig {
		.linuxKernel(LinuxKernelBoot(kernelPath: "/k", initialRamdiskPath: nil, commandLine: ""))
	}
	private func installedMac() -> BootConfig {
		.macOS(MacOSBoot(installState: .installed, minimumCPUCount: 4, minimumMemorySize: 8))
	}

	@Test func efiAndKernelTransitionsAreFree() throws {
		try BootConfig.validateTransition(from: .efi, to: kernel())
		try BootConfig.validateTransition(from: kernel(), to: .efi)
	}

	@Test func installedMacOSCannotChangeMode() {
		#expect(throws: BootConfigError.macOSLocked) {
			try BootConfig.validateTransition(from: installedMac(), to: .efi)
		}
	}

	@Test func installedMacOSStayingMacOSIsAllowed() throws {
		try BootConfig.validateTransition(from: installedMac(), to: installedMac())
	}

	@Test func interruptedOrFailedMacOSCanRevert() throws {
		let installing = BootConfig.macOS(MacOSBoot(installState: .installing,
			minimumCPUCount: 4, minimumMemorySize: 8))
		try BootConfig.validateTransition(from: installing, to: .efi)
		let failed = BootConfig.macOS(MacOSBoot(installState: .failed("x"),
			minimumCPUCount: 4, minimumMemorySize: 8))
		try BootConfig.validateTransition(from: failed, to: .efi)
	}

	// C11: a boot mode a newer Machman wrote is never replaced here — this build can't know
	// what leaving it would lose. Staying on it (any save) is fine.
	@Test func aNewerBootModeCannotBeLeft() throws {
		let newer = try JSONDecoder().decode(
			BootConfig.self, from: Data(#"{"bhyve":{"_0":{"x":1}}}"#.utf8))
		for next in [BootConfig.efi, kernel(), installedMac()] {
			let error = try #require(throws: MachmanError.self) {
				try BootConfig.validateTransition(from: newer, to: next)
			}
			#expect(error.code == .invalidState)
			#expect(error.message == "A newer version of Machman set this VM\u{2019}s boot mode")
		}
		try BootConfig.validateTransition(from: newer, to: newer)
	}

	// D37: kernel boot with no kernel chosen — the draft kernel boot starts from — failed its
	// start as "Kernel image not found: ", no path and no next step; a missing initramfs came
	// back as VZ's generic error, and an empty one as the process's working directory.
	@Test("D37: kernel boot with no kernel chosen refuses with one sentence")
	func noKernelRefusesWithOneSentence() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "blank")
			let cfg = try VMConfig(name: "blank", memorySize: 2048, cpuCount: 2)
			try cfg.setKernelBoot(enabled: true)
			let checks: [() throws -> Void] = [
				cfg.requireStartable, { _ = try cfg.makeBootLoader() },
			]
			for check in checks {
				let error = try #require(throws: MachmanError.self) { try check() }
				#expect(error.code == .invalidState)
				#expect(error.message == "Choose a kernel for blank before starting it")
			}
		}
	}

	private func kernelBoot(initrd: String?) throws -> (VMConfig, String) {
		try VMConfig.createNewVMDirectory(name: "initrd")
		let cfg = try VMConfig(name: "initrd", memorySize: 2048, cpuCount: 2)
		let kernel = TestEnvironment.scratch + "d37-\(UUID().uuidString).bin"
		try Data("KERNEL".utf8).write(to: URL(fileURLWithPath: kernel))
		try cfg.setKernelBoot(enabled: true)
		try cfg.updateKernelSettings(
			LinuxKernelBoot(kernelPath: kernel, initialRamdiskPath: initrd, commandLine: ""))
		return (cfg, kernel)
	}

	@Test("D37: a missing initramfs has its own sentence")
	func aMissingInitramfsSaysSo() throws {
		try VMTestDir.withRedirectedDir {
			let (cfg, kernel) = try kernelBoot(initrd: "/nowhere/initrd.img")
			defer { try? FileManager.default.removeItem(atPath: kernel) }
			try cfg.requireStartable()
			let error = try #require(throws: VirtualMachineError.self) {
				_ = try cfg.makeBootLoader()
			}
			#expect(MachmanError.userMessage(for: error)
				== "Initramfs not found: /nowhere/initrd.img")
		}
	}

	@Test("D37: an empty initramfs path boots without one")
	func anEmptyInitramfsPathIsNone() throws {
		try VMTestDir.withRedirectedDir {
			let (cfg, kernel) = try kernelBoot(initrd: "")
			defer { try? FileManager.default.removeItem(atPath: kernel) }
			let loader = try #require(try cfg.makeBootLoader() as? VZLinuxBootLoader)
			#expect(loader.kernelURL.path == kernel)
			#expect(loader.initialRamdiskURL == nil)
		}
	}
}
