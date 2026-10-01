//
//  ByteSizeUnitTests.swift
//  MachmanAPITests
//
//  P25: a size field reads a bare number as GB and keeps the decimal point (decision 14).
//  The memory field's bare-bytes default stays as it was.
//

import Testing
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

	@Test func theDefaultStaysBytes() {
		#expect(ByteSize.parse("8") == 8)
		#expect(ByteSize.parse("8g") == 8 * gib)
	}
}
