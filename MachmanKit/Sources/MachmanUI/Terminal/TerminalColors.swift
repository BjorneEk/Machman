//
//  TerminalColors.swift
//  MachmanUI
//
//  A terminal colour scheme as plain "#rrggbb" strings (Codable, portable, diffable) plus the
//  hex⇄NSColor plumbing. The 16-entry ANSI palette is the standard xterm order (0-7 normal,
//  8-15 bright). SwiftTerm's own Color type is mapped in the app target — MachmanUI never links
//  SwiftTerm — so this stays a pure data + AppKit representation.
//

import Foundation
import AppKit

// Eight-bit RGB: the common ground between a "#rrggbb" string, an NSColor and SwiftTerm.Color.
public struct RGB8: Equatable, Sendable {
	public let r: UInt8
	public let g: UInt8
	public let b: UInt8

	public init(r: UInt8, g: UInt8, b: UInt8) {
		self.r = r
		self.g = g
		self.b = b
	}
}

// Parse "#rrggbb" or "rrggbb" (case-insensitive). nil on anything else.
public func parseHexColor(_ string: String) -> RGB8? {
	var s = string.trimmingCharacters(in: .whitespaces)
	if s.hasPrefix("#") { s.removeFirst() }
	guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
	return RGB8(
		r: UInt8((value >> 16) & 0xff),
		g: UInt8((value >> 8) & 0xff),
		b: UInt8(value & 0xff))
}

public func formatHexColor(_ c: RGB8) -> String {
	String(format: "#%02x%02x%02x", c.r, c.g, c.b)
}

public extension NSColor {
	// Device-independent sRGB from an "#rrggbb" string; nil when unparseable.
	convenience init?(hexColor: String) {
		guard let c = parseHexColor(hexColor) else { return nil }
		self.init(
			srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
			blue: CGFloat(c.b) / 255, alpha: 1)
	}
}

// A full terminal colour scheme: the "chrome" colours plus the 16 ANSI palette entries.
public struct TerminalColors: Codable, Equatable, Sendable {
	public var foreground: String
	public var background: String
	public var cursor: String
	public var cursorText: String?
	public var selectionBackground: String
	public var ansi: [String]   // exactly 16: 0-7 normal, 8-15 bright

	public init(
		foreground: String, background: String, cursor: String, cursorText: String? = nil,
		selectionBackground: String, ansi: [String]
	) {
		self.foreground = foreground
		self.background = background
		self.cursor = cursor
		self.cursorText = cursorText
		self.selectionBackground = selectionBackground
		self.ansi = ansi
	}

	// Field by field: a missing or mistyped colour takes OneDark's, and a palette that isn't
	// exactly 16 entries takes OneDark's palette, so one bad key never fails the profile.
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let preset = TerminalTheme.oneDark.colors
		foreground = c.decodeTolerant(String.self, forKey: .foreground) ?? preset.foreground
		background = c.decodeTolerant(String.self, forKey: .background) ?? preset.background
		cursor = c.decodeTolerant(String.self, forKey: .cursor) ?? preset.cursor
		cursorText = c.decodeTolerant(String.self, forKey: .cursorText)
		selectionBackground = c.decodeTolerant(String.self, forKey: .selectionBackground)
			?? preset.selectionBackground
		if let palette = c.decodeTolerant([String].self, forKey: .ansi), palette.count == 16 {
			ansi = palette
		} else {
			ansi = preset.ansi
		}
	}
}

// The built-in colour presets offered in the settings view. OneDark mirrors the user's kitty
// theme and is the default; the two monochrome presets use the standard xterm 16-colour palette.
public enum TerminalTheme: String, CaseIterable, Sendable, Identifiable {
	case oneDark = "OneDark"
	case whiteOnBlack = "White on Black"
	case blackOnWhite = "Black on White"

	public var id: String { rawValue }

	// Standard xterm 16-colour palette (0-7 normal, 8-15 bright), shared by the mono presets.
	private static let xterm16 = [
		"#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
		"#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff",
	]

	public var colors: TerminalColors {
		switch self {
		case .oneDark:
			return TerminalColors(
				foreground: "#979eab", background: "#282c34", cursor: "#cccccc",
				cursorText: "#282c34", selectionBackground: "#979eab",
				ansi: [
					"#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#be5046",
					"#56b6c2", "#979eab", "#393e48", "#d19a66", "#56b6c2", "#e5c07b",
					"#61afef", "#be5046", "#56b6c2", "#abb2bf",
				])
		case .whiteOnBlack:
			return TerminalColors(
				foreground: "#ffffff", background: "#000000", cursor: "#ffffff",
				cursorText: "#000000", selectionBackground: "#3a3a3a", ansi: Self.xterm16)
		case .blackOnWhite:
			return TerminalColors(
				foreground: "#000000", background: "#ffffff", cursor: "#000000",
				cursorText: "#ffffff", selectionBackground: "#b5d5ff", ansi: Self.xterm16)
		}
	}
}
