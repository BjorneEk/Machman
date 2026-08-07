//
//  VMInfo.swift
//  MachmanAPI
//
//  The full description of a VM as served over the API. One shape for list and get — the data
//  is small. Flat structs with optional fields (not Swift-flavored enum encodings) so non-Swift
//  clients see obvious JSON.
//

import Foundation

public struct VMInfo: Codable, Sendable, Equatable, Identifiable {
	public var name: String
	public var state: VMState
	public var created: Date
	public var lastRan: Date?
	public var cpuCount: Int
	public var memoryBytes: UInt64
	public var macAddress: String?
	public var disks: [DiskInfo]
	public var mounts: [MountInfo]
	public var boot: BootInfo
	public var consoleLogPath: String?
	// Whether the engine currently shows a console window for this VM.
	public var consoleOpen: Bool

	public var id: String { name }

	public init(
		name: String, state: VMState, created: Date, lastRan: Date?, cpuCount: Int,
		memoryBytes: UInt64, macAddress: String?, disks: [DiskInfo], mounts: [MountInfo],
		boot: BootInfo, consoleLogPath: String?, consoleOpen: Bool = false
	) {
		self.name = name
		self.state = state
		self.created = created
		self.lastRan = lastRan
		self.cpuCount = cpuCount
		self.memoryBytes = memoryBytes
		self.macAddress = macAddress
		self.disks = disks
		self.mounts = mounts
		self.boot = boot
		self.consoleLogPath = consoleLogPath
		self.consoleOpen = consoleOpen
	}

	// Hand-written decode so payloads predating consoleOpen (and clients that omit it)
	// keep decoding; encode stays synthesized.
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.name = try c.decode(String.self, forKey: .name)
		self.state = try c.decode(VMState.self, forKey: .state)
		self.created = try c.decode(Date.self, forKey: .created)
		self.lastRan = try c.decodeIfPresent(Date.self, forKey: .lastRan)
		self.cpuCount = try c.decode(Int.self, forKey: .cpuCount)
		self.memoryBytes = try c.decode(UInt64.self, forKey: .memoryBytes)
		self.macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
		self.disks = try c.decode([DiskInfo].self, forKey: .disks)
		self.mounts = try c.decode([MountInfo].self, forKey: .mounts)
		self.boot = try c.decode(BootInfo.self, forKey: .boot)
		self.consoleLogPath = try c.decodeIfPresent(String.self, forKey: .consoleLogPath)
		self.consoleOpen = try c.decodeIfPresent(Bool.self, forKey: .consoleOpen) ?? false
	}
}

public enum DiskType: String, Codable, Sendable, Equatable {
	case storage   // a named raw image created and stored inside the VM directory
	case image     // an existing disk image referenced by path
	case iso       // a read-only installer/live image attached as USB mass storage
}

public struct DiskInfo: Codable, Sendable, Equatable, Identifiable {
	public var id: String
	public var type: DiskType
	public var name: String?        // .storage
	public var path: String?        // .image / .iso
	public var sizeBytes: UInt64?

	public init(id: String, type: DiskType, name: String?, path: String?, sizeBytes: UInt64?) {
		self.id = id
		self.type = type
		self.name = name
		self.path = path
		self.sizeBytes = sizeBytes
	}
}

public struct MountInfo: Codable, Sendable, Equatable, Identifiable {
	public var id: String
	public var path: String
	public var tag: String

	public init(id: String, path: String, tag: String) {
		self.id = id
		self.path = path
		self.tag = tag
	}
}

public struct BootInfo: Codable, Sendable, Equatable {
	public enum Mode: String, Codable, Sendable {
		case efi
		case linuxKernel
		case macOS
	}

	public var mode: Mode
	// The persisted kernel-boot draft; survives toggling kernel boot off (mode back to .efi).
	public var kernel: KernelSettings?
	public var macInstallState: MacInstallState?   // .macOS mode only
	// Hardware floors imposed by the boot mode (macOS guests carry install-time minimums).
	public var minCPUCount: Int?
	public var minMemoryBytes: UInt64?

	public init(
		mode: Mode, kernel: KernelSettings?, macInstallState: MacInstallState?,
		minCPUCount: Int?, minMemoryBytes: UInt64?
	) {
		self.mode = mode
		self.kernel = kernel
		self.macInstallState = macInstallState
		self.minCPUCount = minCPUCount
		self.minMemoryBytes = minMemoryBytes
	}

	public var macInstalled: Bool { macInstallState?.kind == .installed }
}

public struct MacInstallState: Codable, Sendable, Equatable {
	public enum Kind: String, Codable, Sendable {
		case installing
		case installed
		case failed
		case interrupted   // persisted "installing" with no live install session
	}

	public var kind: Kind
	public var message: String?   // failure reason for .failed

	public init(kind: Kind, message: String? = nil) {
		self.kind = kind
		self.message = message
	}
}

public struct KernelSettings: Codable, Sendable, Equatable {
	public var kernelPath: String
	public var initrdPath: String?
	public var commandLine: String

	public init(kernelPath: String, initrdPath: String?, commandLine: String) {
		self.kernelPath = kernelPath
		self.initrdPath = initrdPath
		self.commandLine = commandLine
	}
}

public struct ConsoleInfo: Codable, Sendable, Equatable {
	// File-backed serial console output (hvc0), nil for guests without one (macOS).
	public var logPath: String?

	public init(logPath: String?) {
		self.logPath = logPath
	}
}
