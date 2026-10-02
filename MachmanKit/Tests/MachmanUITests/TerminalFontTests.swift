import Testing
import Foundation
import AppKit
import MachmanUI

// The terminal font (H19): profiles defaulted to "VictorMono Nerd Font Mono", which a stock Mac
// doesn't have — terminals silently drew in Menlo while Settings showed VictorMono as
// selected. New profiles now default to SF Mono (the system monospaced face, always present),
// a missing font is labelled "(not installed)" and draws in SF Mono.
@MainActor
struct TerminalFontTests {
	private let missing = "Machman Missing Mono 0"

	@Test func newProfilesUseTheSystemMonospacedFace() {
		#expect(TerminalProfile(name: "x").fontName == "SF Mono")
		#expect(TerminalProfile.oneDarkDefault.fontName == "SF Mono")
	}

	@Test func aProfileWithoutAFontDecodesToTheDefault() throws {
		let profile = try JSONDecoder().decode(
			TerminalProfile.self, from: Data(#"{"name":"x"}"#.utf8))
		#expect(profile.fontName == "SF Mono")
	}

	@Test func theDefaultFaceIsAlwaysInstalled() {
		#expect(TerminalFonts.isInstalled("SF Mono"))
		let font = TerminalFonts.font(named: "SF Mono", size: 13)
		#expect(font.isFixedPitch)
		#expect(font.pointSize == 13)
		#expect(TerminalFonts.label(for: "SF Mono") == "SF Mono")
	}

	@Test func aMissingFontIsMarkedAndFallsBackToTheDefaultFace() {
		#expect(!TerminalFonts.isInstalled(missing))
		#expect(TerminalFonts.label(for: missing) == "\(missing) (not installed)")
		#expect(TerminalFonts.font(named: missing, size: 13).fontName
			== TerminalFonts.font(named: "SF Mono", size: 13).fontName)
	}

	@Test func theFamilyListOffersTheDefault() {
		#expect(TerminalFonts.families.contains("SF Mono"))
		#expect(!TerminalFonts.families.contains(missing))
		#expect(TerminalFonts.families == TerminalFonts.families.sorted())
	}
}
