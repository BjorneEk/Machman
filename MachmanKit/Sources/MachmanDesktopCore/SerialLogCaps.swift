//
//  SerialLogCaps.swift
//  MachmanDesktopCore
//
//  The serial inspector's Max size menu (Q21): Unlimited, the presets, and a cap they don't
//  list (a script may set any up to 1 GB) in size order, so the picker never reads blank
//  (H26). Picking a preset replaces the odd cap. A value here, so a test can read the menu
//  no view shows until it opens.
//

import Foundation
import MachmanAPI

public enum SerialLogCaps {
	public struct Item: Equatable, Sendable {
		public let bytes: UInt64   // 0 is Unlimited
		public let label: String
	}

	public static let presets: [UInt64] = [1 << 20, 10 << 20, 100 << 20]

	// The menu for a port whose cap is `current` (nil or 0: unlimited).
	public static func items(current: UInt64?) -> [Item] {
		var caps = presets
		if let current, current != 0, !presets.contains(current) {
			caps = (caps + [current]).sorted()
		}
		return [Item(bytes: 0, label: "Unlimited")]
			+ caps.map { Item(bytes: $0, label: label($0)) }
	}

	// Rounded like every size; exact bytes where rounding would make it read as a preset.
	static func label(_ cap: UInt64) -> String {
		let shown = ByteSize.display(cap)
		let preset = presets.contains { $0 != cap && ByteSize.display($0) == shown }
		return preset ? ByteSize.format(cap) : shown
	}
}
