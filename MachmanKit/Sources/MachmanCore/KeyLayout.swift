//
//  KeyLayout.swift
//  MachmanCore
//
//  What a key types in a ⌘ chord: the keyboard layout's ⌘ layer, which is how menu key
//  equivalents read a key. On Cyrillic, Greek, Hebrew and Arabic layouts that layer is Latin
//  (K types "л" plainly but "k" under ⌘), and on Dvorak – QWERTY ⌘ it is QWERTY — so the
//  reserved ⌃⌥⌘ chords match on it rather than on the event's own characters. Probed across
//  all 251 system layouts: the ⌘ layer gives printable ASCII for K and F everywhere except
//  Lithuanian-LST1582's F, which is why the ASCII-capable layout is the fallback.
//

import Foundation
import Carbon.HIToolbox

enum KeyLayout {
	// The key's ⌘-layer character in the current layout, else in the ASCII-capable one; nil
	// when neither has layout data or types printable ASCII there. Text Input Sources is
	// main-thread only.
	@MainActor
	static func commandCharacter(keyCode: UInt16) -> String? {
		guard let current = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
			return nil
		}
		return asciiFirst(translate(keyCode, in: current)) {
			TISCopyCurrentASCIICapableKeyboardLayoutInputSource()
				.flatMap { translate(keyCode, in: $0.takeRetainedValue()) }
		}
	}

	// The first candidate that is printable ASCII; the fallback is asked only if needed.
	static func asciiFirst(_ current: String?, fallback: () -> String?) -> String? {
		func printable(_ candidate: String?) -> String? {
			guard let candidate, !candidate.isEmpty,
				candidate.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) })
			else {
				return nil
			}
			return candidate
		}
		return printable(current) ?? printable(fallback())
	}

	// UCKeyTranslate with ⌘ alone held: ⌃ or ⌥ in the modifier state turn the result into
	// control characters or the Option layer. No dead-key state: one key, one answer.
	static func translate(_ keyCode: UInt16, in source: TISInputSource) -> String? {
		guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
		else {
			return nil
		}
		let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
		return data.withUnsafeBytes { buffer -> String? in
			guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
			else {
				return nil
			}
			var deadKeys: UInt32 = 0
			var chars = [UniChar](repeating: 0, count: 4)
			var length = 0
			let status = UCKeyTranslate(
				layout, keyCode, UInt16(kUCKeyActionDown), UInt32(cmdKey >> 8) & 0xFF,
				UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys,
				chars.count, &length, &chars)
			guard status == noErr, length > 0 else { return nil }
			return String(utf16CodeUnits: chars, count: length)
		}
	}
}
