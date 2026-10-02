//
//  ByteSizeDisplayTests.swift
//  MachmanAPITests
//
//  H18: read-only sizes were decimal ("34,36 GB" for a 32 GiB disk) where they weren't
//  truncated to whole GB ("needs up to 0 GB" for a 500 MB disk). Decision 14: binary units
//  labelled GB, rounded, never truncated to zero.
//

import Testing
import Foundation
import MachmanAPI

struct ByteSizeDisplayTests {
	private let posix = Locale(identifier: "en_US_POSIX")

	private func shown(_ bytes: UInt64) -> String {
		ByteSize.display(bytes, locale: posix)
	}

	@Test func wholeSizesReadAsTheirBinaryUnit() {
		#expect(shown(64 << 30) == "64 GB")
		#expect(shown(32 << 30) == "32 GB")
		#expect(shown(754 << 20) == "754 MB")
		#expect(shown(1 << 40) == "1 TB")
		#expect(shown(512) == "512 B")
		#expect(shown(0) == "0 B")
	}

	@Test func oneDecimalBelowAHundredNoneAbove() {
		#expect(shown(1536 << 20) == "1.5 GB")
		#expect(shown((13 << 30) + (205 << 20)) == "13.2 GB")
		#expect(shown((412 << 30) + (300 << 20)) == "412 GB")
	}

	@Test func roundingUpToTheNextUnitStepsUp() {
		#expect(shown((1 << 30) - 1) == "1 GB")
		#expect(shown((1 << 20) - 1) == "1 MB")
	}

	@Test func aSmallSizeIsNeverZero() {
		#expect(shown(500 << 20) == "500 MB")
	}

	@Test func theDecimalMarkFollowsTheLocale() {
		#expect(ByteSize.display(1536 << 20, locale: Locale(identifier: "sv_SE")) == "1,5 GB")
	}
}
