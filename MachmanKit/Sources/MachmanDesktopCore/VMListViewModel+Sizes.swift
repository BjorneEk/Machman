//
//  VMListViewModel+Sizes.swift
//  MachmanDesktopCore
//
//  The size fields' half of decision 14: a bare number is GB, decimals and units are fine,
//  and what is sent is whole MiB. The memory field clamps into the range this Mac and the
//  VM allow — and says so, instead of landing somewhere else silently (H4). The disk grow
//  field takes the target size and refuses, with the reason, what can't be grown to (H3).
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

	public func clampMemory(_ bytes: UInt64, floor: UInt64) -> UInt64 {
		ByteSize.clampMemory(bytes, floor: floor, capabilities: capabilities)
	}

	// `floor` is the VM's own minimum (macOS guests carry install minimums).
	public func memoryEntry(_ text: String, floor: UInt64) -> MemoryEntry {
		guard let parsed = ByteSize.parse(text, bareUnit: .gibibyte) else {
			return MemoryEntry(bytes: nil, note: "Enter a size like 8 or 1.5 GB")
		}
		let rounded = ByteSize.roundToMiB(parsed)
		let clamped = clampMemory(rounded, floor: floor)
		if clamped > rounded {
			return MemoryEntry(bytes: clamped, note: "Raised to this VM’s minimum")
		}
		if clamped < rounded {
			return MemoryEntry(bytes: clamped, note: "Lowered to this Mac’s maximum")
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

	// MARK: - Free space

	// The free-space figure is fetched once per connection: every form that judges a size by
	// it refreshes it as it appears — Duplicate…, the New Disk page and the Grow field (P44).
	public func refreshFreeSpace() async {
		await store.refreshCapabilities()
	}

	// MARK: - Disk grow

	// Why the Grow-to field can't grow `disk` to its text, or nil. Nothing typed is nil too:
	// Grow is simply off and the placeholder says what to enter. Growth past the free space
	// is refused like a new disk that big (the sparse file would be a trap once it fills).
	public func growDiskProblem(_ text: String, disk: DiskInfo) -> String? {
		guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
		guard let bytes = Self.newDiskBytes(text) else {
			return "Enter a size like 64 or 1.5 GB"
		}
		let current = disk.sizeBytes ?? 0
		if bytes <= current {
			return "Disks only grow — enter more than \(ByteSize.display(current))"
		}
		if let free = capabilities?.freeDiskBytes, bytes - current > free {
			return "Only \(ByteSize.display(free)) is free"
		}
		return nil
	}

	// The Grow-to field's Return and button: false (nothing sent, the text stays) while the
	// VM must stop first, the disk can't grow, nothing is typed or the size has a problem.
	@discardableResult
	public func submitGrowDisk(_ vm: VMInfo, diskID: String, text: String) -> Bool {
		guard vm.refusal(.resizeDisk) == nil,
			let disk = vm.disks.first(where: { $0.id == diskID }),
			disk.type == .storage, disk.owned != false,
			!text.trimmingCharacters(in: .whitespaces).isEmpty,
			growDiskProblem(text, disk: disk) == nil,
			let bytes = Self.newDiskBytes(text)
		else { return false }
		resizeDisk(vm.name, diskID: diskID, sizeBytes: bytes)
		return true
	}
}
