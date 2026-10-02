//
//  TerminalFonts.swift
//  MachmanUI
//
//  Which font a terminal draws in (H19). Profiles name a font family; one that isn't
//  installed falls back to the system's monospaced face, SF Mono — the default for new
//  profiles (decision 15). SF Mono ships only as that system face: it can't be loaded by name
//  on a stock Mac, so "SF Mono" is resolved here rather than through NSFont(name:). The
//  settings picker labels a missing font "(not installed)" instead of showing it as a
//  working choice.
//

import AppKit

public enum TerminalFonts {
	public static let systemMonospacedName = "SF Mono"

	// The face a profile's font name draws in: the named font when it is installed,
	// otherwise the system monospaced face.
	public static func font(named name: String, size: CGFloat) -> NSFont {
		if name != systemMonospacedName, let font = NSFont(name: name, size: size) {
			return font
		}
		return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
	}

	public static func isInstalled(_ name: String) -> Bool {
		name == systemMonospacedName || NSFont(name: name, size: 12) != nil
	}

	// The picker's rows: a missing font says so.
	public static func label(for name: String) -> String {
		isInstalled(name) ? name : "\(name) (not installed)"
	}

	// The installed fixed-pitch families plus the system face, sorted. Read once per launch.
	@MainActor
	public static let families: [String] = {
		let installed = NSFontManager.shared.availableFontFamilies.filter { family in
			NSFont(name: family, size: 12)?.isFixedPitch ?? false
		}
		return Set(installed + [systemMonospacedName]).sorted()
	}()
}
