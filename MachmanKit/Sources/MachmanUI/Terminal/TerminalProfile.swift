//
//  TerminalProfile.swift
//  MachmanUI
//
//  A named bundle of terminal-rendering settings. Fields split into two groups that behave
//  differently at runtime: STARTUP-only settings are baked into SwiftTerm's TerminalOptions when a
//  terminal is created and can only change by recreating it (the info panel offers a Reload); LIVE
//  settings (font, colours, key/mouse behaviour) apply to an existing terminal instantly. Purely a
//  data model here — the SwiftTerm mapping lives in the app target.
//

import Foundation

// Cursor shape: our own Codable mirror of SwiftTerm.CursorStyle (which deliberately gains no
// Codable conformance). Mapped to the SwiftTerm enum in the app.
public enum TerminalCursor: String, Codable, CaseIterable, Sendable {
	case blinkBlock
	case block
	case blinkUnderline
	case underline
	case blinkBar
	case bar

	public var label: String {
		switch self {
		case .blinkBlock: return "Block (Blinking)"
		case .block: return "Block"
		case .blinkUnderline: return "Underline (Blinking)"
		case .underline: return "Underline"
		case .blinkBar: return "Bar (Blinking)"
		case .bar: return "Bar"
		}
	}
}

// The subset of a profile baked at terminal-creation time. Equatable/Hashable so the info panel
// can tell when an open terminal's baked settings have drifted from its profile (→ offer Reload).
public struct TerminalStartupSignature: Hashable, Sendable {
	public let scrollback: Int
	public let convertEol: Bool
	public let termName: String
	public let cursor: TerminalCursor
	public let tabStopWidth: Int
}

public struct TerminalProfile: Codable, Identifiable, Equatable, Sendable {
	public var id: UUID
	public var name: String

	// Startup-only (require a Reload to take effect on an already-open terminal).
	public var scrollback: Int
	public var convertEol: Bool
	public var termName: String
	public var cursor: TerminalCursor
	public var tabStopWidth: Int

	// Live (apply to an open terminal immediately).
	public var fontName: String
	public var fontSize: Double
	public var colors: TerminalColors
	public var optionAsMeta: Bool
	public var mouseReporting: Bool

	public init(
		id: UUID = UUID(), name: String, scrollback: Int = 500_000, convertEol: Bool = true,
		termName: String = "xterm-256color", cursor: TerminalCursor = .block,
		tabStopWidth: Int = 8, fontName: String = TerminalProfile.defaultFontName,
		fontSize: Double = 13, colors: TerminalColors = TerminalTheme.oneDark.colors,
		optionAsMeta: Bool = true, mouseReporting: Bool = false
	) {
		self.id = id
		self.name = name
		self.scrollback = scrollback
		self.convertEol = convertEol
		self.termName = termName
		self.cursor = cursor
		self.tabStopWidth = tabStopWidth
		self.fontName = fontName
		self.fontSize = fontSize
		self.colors = colors
		self.optionAsMeta = optionAsMeta
		self.mouseReporting = mouseReporting
	}

	public var startupSignature: TerminalStartupSignature {
		TerminalStartupSignature(
			scrollback: scrollback, convertEol: convertEol, termName: termName,
			cursor: cursor, tabStopWidth: tabStopWidth)
	}

	// Tolerant decode: a field that is absent, retyped or unknown to this build (a cursor style
	// a newer build added) falls back to its default, so one bad value never costs the profile
	// — or, through the store, the whole file.
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.id = c.decodeTolerant(UUID.self, forKey: .id) ?? UUID()
		self.name = c.decodeTolerant(String.self, forKey: .name) ?? "Profile"
		self.scrollback = c.decodeTolerant(Int.self, forKey: .scrollback) ?? 500_000
		self.convertEol = c.decodeTolerant(Bool.self, forKey: .convertEol) ?? true
		self.termName = c.decodeTolerant(String.self, forKey: .termName) ?? "xterm-256color"
		self.cursor = c.decodeTolerant(TerminalCursor.self, forKey: .cursor) ?? .block
		self.tabStopWidth = c.decodeTolerant(Int.self, forKey: .tabStopWidth) ?? 8
		self.fontName = c.decodeTolerant(String.self, forKey: .fontName)
			?? TerminalProfile.defaultFontName
		self.fontSize = c.decodeTolerant(Double.self, forKey: .fontSize) ?? 13
		self.colors = c.decodeTolerant(TerminalColors.self, forKey: .colors)
			?? TerminalTheme.oneDark.colors
		self.optionAsMeta = c.decodeTolerant(Bool.self, forKey: .optionAsMeta) ?? true
		self.mouseReporting = c.decodeTolerant(Bool.self, forKey: .mouseReporting) ?? false
	}
}

public extension TerminalProfile {
	// The built-in default has a fixed id so it stays recognizable across launches and reinstalls,
	// associations that point at it remain valid, and it can be protected from deletion.
	static let defaultID = UUID(uuidString: "0B1D0DEF-0000-0000-0000-000000000001")!
	// The system monospaced face (decision 15), resolved through TerminalFonts: it can't be
	// loaded by name. Profiles keep whatever font they were saved with — no migration.
	static let defaultFontName = TerminalFonts.systemMonospacedName

	// OneDark, mirroring the user's kitty theme. Seeded on first run.
	static var oneDarkDefault: TerminalProfile {
		TerminalProfile(id: defaultID, name: "OneDark", colors: TerminalTheme.oneDark.colors)
	}

	var isDefault: Bool { id == TerminalProfile.defaultID }
}
