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

	// MARK: - Human memory sizes

	private static let kib: UInt64 = 1024
	private static let mib: UInt64 = 1024 * 1024
	private static let gib: UInt64 = 1024 * 1024 * 1024

	// "8" = 8 BYTES (no prefix means exact bytes — clear and consistent); "8g"/"8G"/"8gb" =
	// 8 GiB; "512m"; "2048k". Units are binary. Decimals are accepted with any unit
	// ("1.5g" = 1536 MiB). All whitespace is ignored, so a formatted "8 GB" parses back.
	// nil for anything else.
	public static func parse(_ input: String) -> UInt64? {
		var s = input.lowercased().filter { $0 != " " && $0 != "\t" }
		guard !s.isEmpty else { return nil }
		if s.hasSuffix("b") { s = String(s.dropLast()) }
		var multiplier: Double = 1
		if let unit = s.last, "kmg".contains(unit) {
			switch unit {
			case "k": multiplier = Double(kib)
			case "m": multiplier = Double(mib)
			default: multiplier = Double(gib)
			}
			s = String(s.dropLast())
		}
		s = s.replacingOccurrences(of: ",", with: ".")
		guard !s.isEmpty, s.filter({ $0 == "." }).count <= 1,
			s.allSatisfy({ $0.isNumber || $0 == "." }),
			let value = Double(s), value.isFinite, value >= 0
		else { return nil }
		let bytes = value * multiplier
		guard bytes < 9e18 else { return nil }   // stay well inside UInt64
		return UInt64(bytes)
	}

	// Largest binary prefix that yields a WHOLE number — integers only, never "1.5 GB"
	// (1.5g formats as "1536 MB").
	public static func format(_ bytes: UInt64) -> String {
		if bytes >= gib, bytes % gib == 0 { return "\(bytes / gib) GB" }
		if bytes >= mib, bytes % mib == 0 { return "\(bytes / mib) MB" }
		if bytes >= kib, bytes % kib == 0 { return "\(bytes / kib) KB" }
		return "\(bytes) B"
	}

	// Virtualization requires memory sizes in whole mebibytes; nearest keeps "what was
	// meant" for free-form input.
	public static func roundToMiB(_ bytes: UInt64) -> UInt64 {
		((bytes + mib / 2) / mib) * mib
	}
}
