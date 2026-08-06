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

	public init(maxCPUCount: Int, minMemoryBytes: UInt64, maxMemoryBytes: UInt64, freeDiskBytes: UInt64) {
		self.maxCPUCount = maxCPUCount
		self.minMemoryBytes = minMemoryBytes
		self.maxMemoryBytes = maxMemoryBytes
		self.freeDiskBytes = freeDiskBytes
	}
}
