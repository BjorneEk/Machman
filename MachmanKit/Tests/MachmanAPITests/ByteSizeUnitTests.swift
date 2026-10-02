//
//  ByteSizeUnitTests.swift
//  MachmanAPITests
//
//  P25: a size field reads a bare number as GB and keeps the decimal point (decision 14).
//  The memory field's bare-bytes default stays as it was.
//

import Testing
import Foundation
import MachmanAPI

struct ByteSizeUnitTests {
	private let mib: UInt64 = 1 << 20
	private let gib: UInt64 = 1 << 30

	@Test func aBareNumberTakesTheFieldsUnit() {
		#expect(ByteSize.parse("1.5", bareUnit: .gibibyte) == 1536 * mib)
		#expect(ByteSize.parse("2,5", bareUnit: .gibibyte) == 2560 * mib)
		#expect(ByteSize.parse("64", bareUnit: .gibibyte) == 64 * gib)
		#expect(ByteSize.parse("64 GB", bareUnit: .gibibyte) == 64 * gib)
		#expect(ByteSize.parse("512m", bareUnit: .gibibyte) == 512 * mib)
		#expect(ByteSize.parse("8b", bareUnit: .gibibyte) == 8)
		#expect(ByteSize.parse("lots", bareUnit: .gibibyte) == nil)
		#expect(ByteSize.parse("1.2.3", bareUnit: .gibibyte) == nil)
	}

	// R3-2: display steps up to TB from 1024 GB, so a field must take TB back.
	@Test func terabytesParse() {
		#expect(ByteSize.parse("2 TB", bareUnit: .gibibyte) == 2048 * gib)
		#expect(ByteSize.parse("1.5t", bareUnit: .gibibyte) == 1536 * gib)
		#expect(ByteSize.parse("1T") == 1024 * gib)
		#expect(ByteSize.parse(ByteSize.display(1536 * gib, locale: Locale(identifier: "en")),
			bareUnit: .gibibyte) == 1536 * gib)
	}

	@Test func theDefaultStaysBytes() {
		#expect(ByteSize.parse("8") == 8)
		#expect(ByteSize.parse("8g") == 8 * gib)
	}
}
