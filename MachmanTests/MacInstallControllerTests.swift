import Testing
@testable import Machman_desktop
import MachmanAPI

struct InstallSessionPhaseTests {

	@Test func phaseMapsBootState() {
		#expect(InstallSession.phase(for: .efi, hasActiveInstall: false).kind == .idle)

		let kernel = BootConfig.linuxKernel(
			LinuxKernelBoot(kernelPath: "/k", initialRamdiskPath: nil, commandLine: ""))
		#expect(InstallSession.phase(for: kernel, hasActiveInstall: false).kind == .idle)

		let installing = BootConfig.macOS(
			MacOSBoot(installState: .installing, minimumCPUCount: 1, minimumMemorySize: 1))
		#expect(InstallSession.phase(for: installing, hasActiveInstall: false).kind == .interrupted)
		let active = InstallSession.phase(for: installing, hasActiveInstall: true)
		#expect(active.kind == .installing)
		#expect(active.version == "macOS")

		let installed = BootConfig.macOS(
			MacOSBoot(installState: .installed, minimumCPUCount: 1, minimumMemorySize: 1))
		#expect(InstallSession.phase(for: installed, hasActiveInstall: false).kind == .installed)

		let failed = BootConfig.macOS(
			MacOSBoot(installState: .failed("x"), minimumCPUCount: 1, minimumMemorySize: 1))
		let failedPhase = InstallSession.phase(for: failed, hasActiveInstall: false)
		#expect(failedPhase.kind == .failed)
		#expect(failedPhase.message == "x")
	}
}
