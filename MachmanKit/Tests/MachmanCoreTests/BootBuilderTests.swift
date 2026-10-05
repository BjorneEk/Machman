import Testing
import Foundation
import MachmanAPI
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
}
