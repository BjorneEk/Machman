//
//  ByteSize.swift
//  MachmanAPI
//
//  Byte/GB helpers clients need for editing UIs, plus memory clamping against host
//  capabilities — so clients never need Virtualization.framework for bounds math.
//

import Foundation

public enum ByteSize {
	public static func fromGB(_ gb: Int) -> UInt64 {
		UInt64(max(gb, 0)) * 1024 * 1024 * 1024
	}

	public static func toGB(_ bytes: UInt64) -> Int {
		Int(bytes / (1024 * 1024 * 1024))
	}

	// `floor` lets a boot mode raise the lower bound (macOS guests carry install minimums).
	public static func clampMemory(
		_ bytes: UInt64, floor: UInt64, capabilities: HostCapabilities?
	) -> UInt64 {
		guard let caps = capabilities else { return max(bytes, floor) }
		let lower = max(floor, caps.minMemoryBytes)
		return min(max(bytes, lower), caps.maxMemoryBytes)
	}
}
