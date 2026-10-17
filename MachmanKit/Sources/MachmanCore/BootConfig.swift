//
//  BootConfig.swift
//  Machman
//
//  How a VM boots. The common ~90% of VMConfig is shared; only this facet varies, so it lives
//  as a composed enum member on VMConfig rather than a VMConfig subclass. Adding a new boot mode
//  is one case here (and one key in its coding below) plus one arm in the VMDevices builders.
//

import Foundation
import MachmanAPI

enum BootConfig: Equatable {
	case efi                            // generic EFI machine (the default / current behavior)
	case linuxKernel(LinuxKernelBoot)   // direct kernel boot, no EFI variable store
	case macOS(MacOSBoot)               // Apple-silicon macOS guest; locked once installed
	// A boot mode a newer Machman wrote (D26), kept as read: a save writes it back, and this
	// build never starts it or replaces it (VMConfig.requireStartable, validateTransition,
	// the macOS installer).
	case unknown(JSONValue)
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

// The on-disk shape is the one the synthesized enum coding wrote — {"efi":{}},
// {"linuxKernel":{"_0":{…}}}, {"macOS":{"_0":{…}}} — and every config on disk carries it, so it
// is FROZEN. What doesn't decode as one of those (a newer mode, or a known mode whose payload
// this build can't read, like a newer install state) is kept whole as .unknown and written back
// as read: the VM stays in the list instead of vanishing from it (D26).
extension BootConfig: Codable {
	private enum CodingKeys: String, CodingKey {
		case efi
		case linuxKernel
		case macOS
	}

	private enum PayloadKeys: String, CodingKey {
		case _0
	}

	init(from decoder: any Decoder) throws {
		if let known = try? Self.decodeKnown(from: decoder) {
			self = known
		} else {
			self = .unknown(try JSONValue(from: decoder))
		}
	}

	private static func decodeKnown(from decoder: any Decoder) throws -> BootConfig {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		guard c.allKeys.count == 1, let key = c.allKeys.first else {
			throw DecodingError.dataCorrupted(DecodingError.Context(
				codingPath: c.codingPath, debugDescription: "Not a boot mode this build knows"))
		}
		switch key {
		case .efi:
			_ = try c.nestedContainer(keyedBy: PayloadKeys.self, forKey: key)
			return .efi
		case .linuxKernel:
			let payload = try c.nestedContainer(keyedBy: PayloadKeys.self, forKey: key)
			return .linuxKernel(try payload.decode(LinuxKernelBoot.self, forKey: ._0))
		case .macOS:
			let payload = try c.nestedContainer(keyedBy: PayloadKeys.self, forKey: key)
			return .macOS(try payload.decode(MacOSBoot.self, forKey: ._0))
		}
	}

	func encode(to encoder: any Encoder) throws {
		if case .unknown(let value) = self {
			try value.encode(to: encoder)
			return
		}
		var c = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .efi:
			_ = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .efi)
		case .linuxKernel(let kernel):
			var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .linuxKernel)
			try payload.encode(kernel, forKey: ._0)
		case .macOS(let mac):
			var payload = c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .macOS)
			try payload.encode(mac, forKey: ._0)
		case .unknown:
			break   // written above
		}
	}
}

extension BootConfig {
	// What refuses to start or replace a boot mode a newer Machman wrote (C11): one sentence
	// for every such refusal, shared with the desktop's inspector.
	static var newerModeRefusal: MachmanError {
		MachmanError(code: .invalidState, message: BootInfo.newerModeReason)
	}

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
	// interrupted/failed macOS install may still be reverted. A newer Machman's mode is never
	// left (C11): this build can't know what leaving it would lose — the refusal is a
	// MachmanError, not a BootConfigError, so it isn't worded as the macOS lock. Pure (no I/O)
	// so it's easy to test.
	static func validateTransition(from current: BootConfig, to next: BootConfig) throws {
		if case .unknown = current, next != current {
			throw newerModeRefusal
		}
		if current.isMacInstalled {
			if case .macOS = next { return }   // staying macOS is fine
			throw BootConfigError.macOSLocked
		}
	}
}
