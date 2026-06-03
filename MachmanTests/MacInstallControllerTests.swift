import Testing
@testable import Machman

struct MacInstallControllerTests {

	@Test func phaseMapsBootState() {
		#expect(MacInstallController.phase(for: .efi, hasActiveInstall: false) == .idle)

		let kernel = BootConfig.linuxKernel(
			LinuxKernelBoot(kernelPath: "/k", initialRamdiskPath: nil, commandLine: ""))
		#expect(MacInstallController.phase(for: kernel, hasActiveInstall: false) == .idle)

		let installing = BootConfig.macOS(
			MacOSBoot(installState: .installing, minimumCPUCount: 1, minimumMemorySize: 1))
		#expect(MacInstallController.phase(for: installing, hasActiveInstall: false) == .interrupted)
		#expect(MacInstallController.phase(for: installing, hasActiveInstall: true)
			== .installing(version: "macOS"))

		let installed = BootConfig.macOS(
			MacOSBoot(installState: .installed, minimumCPUCount: 1, minimumMemorySize: 1))
		#expect(MacInstallController.phase(for: installed, hasActiveInstall: false) == .installed)

		let failed = BootConfig.macOS(
			MacOSBoot(installState: .failed("x"), minimumCPUCount: 1, minimumMemorySize: 1))
		#expect(MacInstallController.phase(for: failed, hasActiveInstall: false) == .failed("x"))
	}
}
