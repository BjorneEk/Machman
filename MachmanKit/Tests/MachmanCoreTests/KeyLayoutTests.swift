//
//  KeyLayoutTests.swift
//  MachmanTests
//
//  V3: the reserved chords' keys on the ⌘ layer of real system keyboard layouts (bundled
//  with macOS; a renamed layout fails the #require loudly). Key codes are ANSI positions:
//  40 = K, 3 = F, 9 = V. Text Input Sources is main-thread only.
//

import Testing
import Foundation
import Carbon.HIToolbox
@testable import MachmanCore

@MainActor
struct KeyLayoutTests {
	private func layout(_ id: String) -> TISInputSource? {
		let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
		let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue()
		return (list as? [TISInputSource])?.first
	}

	@Test(arguments: [
		("com.apple.keylayout.US", UInt16(40), "k"),
		("com.apple.keylayout.Russian", 40, "k"),     // plainly "л"
		("com.apple.keylayout.Greek", 3, "f"),        // plainly "φ"
		("com.apple.keylayout.Hebrew", 40, "k"),      // plainly "ל"
		("com.apple.keylayout.DVORAK-QWERTYCMD", 40, "k"),   // plainly "t"
		("com.apple.keylayout.DVORAK-QWERTYCMD", 9, "v"),    // plainly "k"
		("com.apple.keylayout.Dvorak", 9, "k"),
	])
	func theCommandLayerOfARealLayout(id: String, keyCode: UInt16, expected: String) throws {
		let source = try #require(layout(id), "\(id) is not installed")
		#expect(KeyLayout.translate(keyCode, in: source) == expected)
	}

	@Test func theFirstPrintableASCIICandidateWins() {
		#expect(KeyLayout.asciiFirst("š", fallback: { "f" }) == "f")
		#expect(KeyLayout.asciiFirst("\u{0B}", fallback: { nil }) == nil)   // ⌃K's control char
		#expect(KeyLayout.asciiFirst(nil, fallback: { "k" }) == "k")
		var asked = false
		#expect(KeyLayout.asciiFirst("k", fallback: { asked = true; return "x" }) == "k")
		#expect(!asked)
	}
}
