//
//  HostCapabilities.swift
//  MachmanAPI
//
//  Host-side limits clients need for editing UIs (stepper ranges, size caps) without touching
//  Virtualization.framework themselves.
//

import Foundation

public struct HostCapabilities: Codable, Sendable, Equatable {
	public var maxCPUCount: Int
	public var minMemoryBytes: UInt64
	public var maxMemoryBytes: UInt64
	public var freeDiskBytes: UInt64   // free space on the volume holding the VM data dir
	// 1.0.4 additions — all Optional (nil = older daemon; consumers must tolerate).
	// Set when configured uart ports cannot attach on this host (the PL011 gate).
	public var uartUnavailable: UnavailabilityInfo?
	// VZGenericPlatformConfiguration.isNestedVirtualizationSupported (M3+, EFI/kernel boots).
	public var nestedVirtualizationSupported: Bool?
	// VZLinuxRosettaDirectoryShare.availability: "notSupported" | "notInstalled" | "installed".
	public var rosettaAvailability: String?
	// The daemon's main-screen pixel size, for the graphics inspector's "host size" preset.
	public var hostDisplayWidthPixels: Int?
	public var hostDisplayHeightPixels: Int?
	// The engine's total serial-port budget per VM (console + uart combined).
	public var maxSerialPorts: Int?

	public init(
		maxCPUCount: Int, minMemoryBytes: UInt64, maxMemoryBytes: UInt64,
		freeDiskBytes: UInt64, uartUnavailable: UnavailabilityInfo? = nil,
		nestedVirtualizationSupported: Bool? = nil, rosettaAvailability: String? = nil,
		hostDisplayWidthPixels: Int? = nil, hostDisplayHeightPixels: Int? = nil,
		maxSerialPorts: Int? = nil
	) {
		self.maxCPUCount = maxCPUCount
		self.minMemoryBytes = minMemoryBytes
		self.maxMemoryBytes = maxMemoryBytes
		self.freeDiskBytes = freeDiskBytes
		self.uartUnavailable = uartUnavailable
		self.nestedVirtualizationSupported = nestedVirtualizationSupported
		self.rosettaAvailability = rosettaAvailability
		self.hostDisplayWidthPixels = hostDisplayWidthPixels
		self.hostDisplayHeightPixels = hostDisplayHeightPixels
		self.maxSerialPorts = maxSerialPorts
	}
}

// Wire values for HostCapabilities.rosettaAvailability (open string set on the wire).
public enum RosettaAvailability {
	public static let notSupported = "notSupported"
	public static let notInstalled = "notInstalled"
	public static let installed = "installed"
}
