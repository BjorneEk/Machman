//
//  MacSystemDisk.swift
//  MachmanAPI
//
//  The disk a macOS install restores onto (D32, K4): a new one, or one of the VM's own disks
//  the user picks, which the install erases. Shared by the engine (the new disk's size) and the
//  switch sheet (its titles and its warning).
//

import Foundation

public enum MacSystemDisk {
	// What a new macOS disk gets.
	public static let newDiskBytes: UInt64 = 64 << 30

	// Below this, a picked disk is offered with a warning — never refused (K15): what macOS
	// needs is the install's to say, not a number of ours.
	public static let roomyBytes: UInt64 = newDiskBytes

	public static var mayNotFitWarning: String {
		"macOS may not fit on a disk under \(ByteSize.display(roomyBytes))"
	}
}
