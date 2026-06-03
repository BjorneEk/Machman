import Testing
@testable import Machman

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
}
