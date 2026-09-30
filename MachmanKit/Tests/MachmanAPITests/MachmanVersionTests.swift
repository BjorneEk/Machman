//
//  MachmanVersionTests.swift
//  MachmanTests
//

import Testing
import MachmanAPI

struct MachmanVersionTests {
	@Test func componentComparison() {
		#expect(MachmanVersion.isOlder("1.0", than: "1.0.1"))
		#expect(MachmanVersion.isOlder("1.0.1", than: "1.0.2"))
		#expect(MachmanVersion.isOlder("1.0.9", than: "1.1"))
		#expect(!MachmanVersion.isOlder("1.0.1", than: "1.0.1"))
		#expect(!MachmanVersion.isOlder("2.0", than: "1.9.9"))
	}

	@Test func suffixesAreIgnored() {
		#expect(MachmanVersion.compare("1.0.1-vmhost", "1.0.1") == .orderedSame)
		#expect(MachmanVersion.isOlder("1.0-vmhost", than: "1.0.1"))
	}

	@Test func unparseableIsOldest() {
		#expect(MachmanVersion.isOlder("dev", than: "1.0.1"))
		#expect(MachmanVersion.isOlder("", than: "0.0.1"))
		#expect(MachmanVersion.compare("dev", "junk") == .orderedSame)
	}
}
