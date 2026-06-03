//
//  BootConfig.swift
//  Machman
//
//  How a VM boots. The common ~90% of VMConfig is shared; only this facet varies, so it lives
//  as a composed enum member on VMConfig rather than a VMConfig subclass. Adding a new boot mode
//  is one case here plus one arm in the VMDevices builders.
//

import Foundation

enum BootConfig: Codable, Equatable {
	case efi                            // generic EFI machine (the default / current behavior)
	case linuxKernel(LinuxKernelBoot)   // direct kernel boot, no EFI variable store
	case macOS(MacOSBoot)               // Apple-silicon macOS guest; locked once installed
}

struct LinuxKernelBoot: Codable, Equatable {
	var kernelPath: String
	var initialRamdiskPath: String?
	var commandLine: String             // e.g. "console=hvc0 root=/dev/vda1 rw"
}

struct MacOSBoot: Codable, Equatable {
	var installState: MacInstallState
	var minimumCPUCount: Int
	var minimumMemorySize: UInt64
}

enum MacInstallState: Codable, Equatable {
	case installing     // transient; seeing this on load means a prior install was interrupted
	case installed
	case failed(String)
}

enum BootConfigError: Error, Equatable {
	case macOSLocked
}

extension BootConfig {
	var isMacInstalled: Bool {
		if case .macOS(let m) = self, m.installState == .installed { return true }
		return false
	}

	// CPU/memory minimums imposed by the boot mode (macOS guests carry install-time minimums).
	var hardwareFloors: (cpu: Int, mem: UInt64)? {
		if case .macOS(let m) = self {
			return (cpu: m.minimumCPUCount, mem: m.minimumMemorySize)
		}
		return nil
	}

	// Whether the boot mode may change from `current` to `next`. macOS is a creation-time
	// identity: once installed it can't become EFI/kernel. EFI <-> linuxKernel is free, and an
	// interrupted/failed macOS install may still be reverted. Pure (no I/O) so it's easy to test.
	static func validateTransition(from current: BootConfig, to next: BootConfig) throws {
		if current.isMacInstalled {
			if case .macOS = next { return }   // staying macOS is fine
			throw BootConfigError.macOSLocked
		}
	}
}
