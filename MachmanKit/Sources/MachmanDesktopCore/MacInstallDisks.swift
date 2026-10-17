//
//  MacInstallDisks.swift
//  MachmanDesktopCore
//
//  The macOS switch sheet's question (D32, K4): install onto a new disk — the preselected
//  answer, placed first — or onto one of the VM's own disks, which the install erases. A retry
//  asks nothing: it reuses its own first disk. A disk smaller than a new one may still be
//  picked, with a warning (K15).
//

import Foundation
import MachmanAPI

public enum MacInstallDisks {
	// The disks the sheet offers to erase: the VM's writable ones (owned storage and images),
	// switched on or off, in list order. None on a retry, or for a VM without one.
	public static func offered(for vm: VMInfo) -> [DiskInfo] {
		guard vm.boot.mode != .macOS else { return [] }
		return vm.disks.filter { $0.type == .storage || $0.type == .image }
	}

	public static var newDiskTitle: String {
		"A new disk (\(ByteSize.display(MacSystemDisk.newDiskBytes)))"
	}

	// "system (32 GB)"; an image by its file name.
	public static func title(_ disk: DiskInfo) -> String {
		guard let size = disk.sizeBytes else { return name(disk) }
		return "\(name(disk)) (\(ByteSize.display(size)))"
	}

	// Why macOS may not fit on a disk smaller than a new one gets, or nil.
	public static func sizeWarning(_ disk: DiskInfo) -> String? {
		guard let size = disk.sizeBytes, size < MacSystemDisk.roomyBytes else { return nil }
		return MacSystemDisk.mayNotFitWarning
	}

	// What the sheet says under the choice once an existing disk is picked.
	public static func notes(_ disk: DiskInfo) -> [String] {
		["Installing erases \u{201C}\(name(disk))\u{201D} and can\u{2019}t be undone."]
			+ (sizeWarning(disk).map { [$0 + "."] } ?? [])
	}

	private static func name(_ disk: DiskInfo) -> String {
		disk.name ?? disk.path.map { ($0 as NSString).lastPathComponent } ?? disk.id
	}
}
