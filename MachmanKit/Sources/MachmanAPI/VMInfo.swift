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
	// Whether the engine currently shows a window for this VM.
	public var windowOpen: Bool
	// Optional (not defaulted): genuinely absent from older daemons.
	public var startPolicy: StartPolicy?
	// Set by the daemon only, and only while a safe run impersonates this VM (phase 6).
	public var safeRun: Bool?
	public var totalRuntimeSeconds: Double?
	// Serial ports by family (nil = older daemon). Counts are the array lengths; each port's
	// socketPath is present only while the VM runs.
	public var consolePorts: [SerialPortInfo]?
	public var uartPorts: [SerialPortInfo]?
	// Guest devices (nil = older daemon; clients derive ImpliedDevices.kinds instead).
	public var devices: [DeviceInfo]?
	// Nested virtualization flag (EFI/kernel boots on supporting hardware; nil = older
	// daemon / off).
	public var nestedVirtualization: Bool?
	// SSH autoconfiguration state (1.0.5; nil = older daemon or SSH never used). The
	// address half is a daemon overlay, like safeRun.
	public var ssh: SSHInfo?

	public var id: String { name }

	public init(
		name: String, state: VMState, created: Date, lastRan: Date?, cpuCount: Int,
		memoryBytes: UInt64, macAddress: String?, disks: [DiskInfo], mounts: [MountInfo],
		boot: BootInfo, windowOpen: Bool = false,
		startPolicy: StartPolicy? = nil, safeRun: Bool? = nil,
		totalRuntimeSeconds: Double? = nil,
		consolePorts: [SerialPortInfo]? = nil, uartPorts: [SerialPortInfo]? = nil,
		devices: [DeviceInfo]? = nil, nestedVirtualization: Bool? = nil,
		ssh: SSHInfo? = nil
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
		self.windowOpen = windowOpen
		self.startPolicy = startPolicy
		self.safeRun = safeRun
		self.totalRuntimeSeconds = totalRuntimeSeconds
		self.consolePorts = consolePorts
		self.uartPorts = uartPorts
		self.devices = devices
		self.nestedVirtualization = nestedVirtualization
		self.ssh = ssh
	}

	// Hand-written decode so payloads predating the optional fields (and clients that omit
	// them) keep decoding; encode stays synthesized, so nil optionals are omitted.
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
		self.windowOpen = try c.decodeIfPresent(Bool.self, forKey: .windowOpen) ?? false
		self.startPolicy = try c.decodeIfPresent(StartPolicy.self, forKey: .startPolicy)
		self.safeRun = try c.decodeIfPresent(Bool.self, forKey: .safeRun)
		self.totalRuntimeSeconds =
			try c.decodeIfPresent(Double.self, forKey: .totalRuntimeSeconds)
		self.consolePorts = try c.decodeIfPresent([SerialPortInfo].self, forKey: .consolePorts)
		self.uartPorts = try c.decodeIfPresent([SerialPortInfo].self, forKey: .uartPorts)
		self.devices = try c.decodeIfPresent([DeviceInfo].self, forKey: .devices)
		self.nestedVirtualization =
			try c.decodeIfPresent(Bool.self, forKey: .nestedVirtualization)
		self.ssh = try c.decodeIfPresent(SSHInfo.self, forKey: .ssh)
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
	public var path: String?        // .image/.iso: the user's file; .storage: server-resolved
	                                // absolute path (clients must not derive library paths)
	public var sizeBytes: UInt64?
	// Safe-mode policy: true = a safe run clones this disk. Non-optional with a default-true
	// decode (the windowOpen pattern) — the daemon always populates it.
	public var safe: Bool
	// true = the backing file lives inside (and travels with) the VM's directory; false =
	// an external reference vm.disk.promote can copy in. Optional so old daemons (nil)
	// simply hide the promote affordance; nil is omitted on the wire.
	public var owned: Bool?
	// Disabled disks stay configured but are not attached at the next start. Tri-state:
	// nil = enabled (and what older daemons report); nil is omitted on the wire.
	public var enabled: Bool?

	public init(
		id: String, type: DiskType, name: String?, path: String?, sizeBytes: UInt64?,
		safe: Bool = true, owned: Bool? = nil, enabled: Bool? = nil
	) {
		self.id = id
		self.type = type
		self.name = name
		self.path = path
		self.sizeBytes = sizeBytes
		self.safe = safe
		self.owned = owned
		self.enabled = enabled
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try c.decode(String.self, forKey: .id)
		self.type = try c.decode(DiskType.self, forKey: .type)
		self.name = try c.decodeIfPresent(String.self, forKey: .name)
		self.path = try c.decodeIfPresent(String.self, forKey: .path)
		self.sizeBytes = try c.decodeIfPresent(UInt64.self, forKey: .sizeBytes)
		self.safe = try c.decodeIfPresent(Bool.self, forKey: .safe) ?? true
		self.owned = try c.decodeIfPresent(Bool.self, forKey: .owned)
		self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
	}

	// Effective attachment state: nil means enabled.
	public var isEnabled: Bool { enabled ?? true }
}

public struct MountInfo: Codable, Sendable, Equatable, Identifiable {
	public var id: String
	public var path: String
	public var tag: String
	// Safe-mode policy: true = a safe run omits this mount (default-true decode, see DiskInfo).
	public var safe: Bool
	// Disabled mounts are not shared at the next start. Tri-state, nil = enabled (DiskInfo
	// pattern).
	public var enabled: Bool?

	public init(id: String, path: String, tag: String, safe: Bool = true, enabled: Bool? = nil) {
		self.id = id
		self.path = path
		self.tag = tag
		self.safe = safe
		self.enabled = enabled
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try c.decode(String.self, forKey: .id)
		self.path = try c.decode(String.self, forKey: .path)
		self.tag = try c.decode(String.self, forKey: .tag)
		self.safe = try c.decodeIfPresent(Bool.self, forKey: .safe) ?? true
		self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
	}

	public var isEnabled: Bool { enabled ?? true }
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
	// Kernel/initramfs files copied into the VM (owned). nil = older daemon; the boot editor
	// offers these in its kernel/initramfs pickers (filtered by role).
	public var ownedKernels: [OwnedKernelFile]?

	public init(
		mode: Mode, kernel: KernelSettings?, macInstallState: MacInstallState?,
		minCPUCount: Int?, minMemoryBytes: UInt64?, ownedKernels: [OwnedKernelFile]? = nil
	) {
		self.mode = mode
		self.kernel = kernel
		self.macInstallState = macInstallState
		self.minCPUCount = minCPUCount
		self.minMemoryBytes = minMemoryBytes
		self.ownedKernels = ownedKernels
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

// Which kernel-boot file a promote/delete targets.
public enum KernelRole: String, Codable, Sendable, Equatable {
	case kernel
	case initramfs
}

// An owned kernel/initramfs file: a copy living at <vm>/kernels/<role>/<tag>/<fileName>. The tag
// is a user-facing label (the boot editor shows "<tag> - <fileName>"); role separates the kernel
// and initramfs pickers.
public struct OwnedKernelFile: Codable, Sendable, Equatable, Identifiable {
	public var role: KernelRole
	public var tag: String
	public var fileName: String
	public var path: String
	// Per-file command-line override: when overrideEnabled == true and this kernel is the
	// active one, overrideCommandLine replaces KernelSettings.commandLine at boot. Tri-state
	// optionals (nil = none/off = what older daemons report); synthesized decode tolerates
	// their absence.
	public var overrideCommandLine: String?
	public var overrideEnabled: Bool?

	public var id: String { path }

	public init(
		role: KernelRole, tag: String, fileName: String, path: String,
		overrideCommandLine: String? = nil, overrideEnabled: Bool? = nil
	) {
		self.role = role
		self.tag = tag
		self.fileName = fileName
		self.path = path
		self.overrideCommandLine = overrideCommandLine
		self.overrideEnabled = overrideEnabled
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
