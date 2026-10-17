//
//  POSIXChecksum.swift
//  MachmanCore
//
//  POSIX cksum (CRC-32, polynomial 0x04C11DB7, the length's bytes folded in after the data,
//  complemented): what every guest's own `cksum` prints for the same bytes, busybox's and
//  the BSDs' included, so a guest can check a file Machman wrote without a hash tool it may
//  lack. A change detector, not a security check.
//

import Foundation

enum POSIXChecksum {
	private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
		var crc = UInt32(index) << 24
		for _ in 0..<8 {
			crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
		}
		return crc
	}

	// "<crc> <length>", as `cksum < file` prints it.
	static func cksum(_ data: Data) -> String {
		var crc: UInt32 = 0
		func add(_ byte: UInt8) {
			crc = (crc << 8) ^ table[Int((crc >> 24) ^ UInt32(byte))]
		}
		for byte in data { add(byte) }
		var length = data.count
		while length > 0 {
			add(UInt8(length & 0xFF))
			length >>= 8
		}
		return "\(~crc) \(data.count)"
	}
}
