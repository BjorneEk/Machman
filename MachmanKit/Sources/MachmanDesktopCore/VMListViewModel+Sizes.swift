//
//  VMListViewModel+Sizes.swift
//  MachmanDesktopCore
//
//  The size fields' half of decision 14: a bare number is GB, decimals and units are fine,
//  and what is sent is whole MiB. The memory field clamps into the range this Mac and the
//  VM allow — and says so, instead of landing somewhere else silently (H4).
//

import Foundation
import MachmanAPI

// What the memory field makes of its text: the bytes to show and send (nil = unreadable,
// nothing sent) and the one sentence to show under the row, if any.
public struct MemoryEntry: Equatable, Sendable {
	public var bytes: UInt64?
	public var note: String?

	public init(bytes: UInt64?, note: String?) {
		self.bytes = bytes
		self.note = note
	}
}

extension VMListViewModel {
	// MARK: - Memory

	// `floor` is the VM's own minimum (macOS guests carry install minimums).
	public func memoryEntry(_ text: String, floor: UInt64) -> MemoryEntry {
		guard let parsed = ByteSize.parse(text, bareUnit: .gibibyte) else {
			return MemoryEntry(bytes: nil, note: "Enter a size like 8 or 1.5 GB")
		}
		let rounded = ByteSize.roundToMiB(parsed)
		let clamped = clampMemory(rounded, floor: floor)
		if clamped > rounded {
			return MemoryEntry(bytes: clamped, note: "Raised to this VM's minimum")
		}
		if clamped < rounded {
			return MemoryEntry(bytes: clamped, note: "Lowered to this Mac's maximum")
		}
		return MemoryEntry(bytes: clamped, note: nil)
	}

	// The memory field's Return: sends the entry when it is readable and differs from what
	// the VM has; returns it either way so the field can show the value and the note.
	@discardableResult
	public func submitMemory(_ vm: VMInfo, text: String) -> MemoryEntry {
		let entry = memoryEntry(text, floor: vm.boot.minMemoryBytes ?? 0)
		if let bytes = entry.bytes, bytes != vm.memoryBytes {
			setHardware(vm.name, memoryBytes: bytes)
		}
		return entry
	}
}
