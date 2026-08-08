//
//  MemorySizeTests.swift
//  MachmanTests
//
//  Pins the human memory-size contract: bare numbers are BYTES, k/m/g[b] are binary units,
//  decimals parse but never display, formatting picks the largest whole-number prefix.
//

import Testing
import MachmanAPI

struct MemorySizeTests {
	private let kib: UInt64 = 1024
	private let mib: UInt64 = 1024 * 1024
	private let gib: UInt64 = 1024 * 1024 * 1024

	@Test func bareNumbersAreBytes() {
		#expect(ByteSize.parse("8") == 8)
		#expect(ByteSize.parse("1073741824") == gib)
		#expect(ByteSize.parse("8b") == 8)
	}

	@Test func prefixesAreBinaryAndCaseInsensitive() {
		#expect(ByteSize.parse("8g") == 8 * gib)
		#expect(ByteSize.parse("8G") == 8 * gib)
		#expect(ByteSize.parse("8gb") == 8 * gib)
		#expect(ByteSize.parse("8 GB") == 8 * gib)   // a formatted value parses back
		#expect(ByteSize.parse("512m") == 512 * mib)
		#expect(ByteSize.parse("2048k") == 2 * mib)
	}

	@Test func decimalsParseWithEitherSeparator() {
		#expect(ByteSize.parse("1.5g") == 1536 * mib)
		#expect(ByteSize.parse("1,5g") == 1536 * mib)
		#expect(ByteSize.parse("0.5G") == 512 * mib)
	}

	@Test func junkIsRejected() {
		#expect(ByteSize.parse("") == nil)
		#expect(ByteSize.parse("abc") == nil)
		#expect(ByteSize.parse("1.2.3g") == nil)
		#expect(ByteSize.parse("g") == nil)
		#expect(ByteSize.parse("b") == nil)
		#expect(ByteSize.parse("-8g") == nil)
	}

	@Test func formatUsesTheLargestWholePrefix() {
		#expect(ByteSize.format(8 * gib) == "8 GB")
		#expect(ByteSize.format(1536 * mib) == "1536 MB")   // never "1.5 GB"
		#expect(ByteSize.format(1 * mib) == "1 MB")
		#expect(ByteSize.format(2 * kib) == "2 KB")
		#expect(ByteSize.format(500) == "500 B")
	}

	@Test func roundToMiBSnapsToTheNearestMebibyte() {
		#expect(ByteSize.roundToMiB(gib) == gib)
		#expect(ByteSize.roundToMiB(mib - 1) == mib)
		#expect(ByteSize.roundToMiB(mib / 2 - 1) == 0)
	}
}
