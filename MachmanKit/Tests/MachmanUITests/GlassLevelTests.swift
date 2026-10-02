import Testing
import SwiftUI
import MachmanUI

// Extra glass (H20, A-3e-1): the theme key had no control and changed only the macOS < 26
// fallback material, so on macOS 26 it did nothing. Settings ▸ Appearance now sets it, and
// on macOS 26 it picks Liquid Glass's clear variant; the fallback keeps ultra-thin material.
struct GlassLevelTests {
	@Test func extraGlassIsTheClearVariant() {
		guard #available(macOS 26.0, *) else { return }
		#expect(Glass.clear != Glass.regular)   // equality tells the variants apart
		#expect(MachmanGlassLevel.extra.liquidGlass(prominent: false, tint: nil) == .clear)
		#expect(MachmanGlassLevel.standard.liquidGlass(prominent: false, tint: nil) == .regular)
	}

	@Test func prominenceAndTintCarryOver() {
		guard #available(macOS 26.0, *) else { return }
		#expect(MachmanGlassLevel.extra.liquidGlass(prominent: true, tint: nil)
			== Glass.clear.interactive())
		#expect(MachmanGlassLevel.extra.liquidGlass(prominent: false, tint: .orange)
			== Glass.clear.tint(.orange))
		#expect(MachmanGlassLevel.standard.liquidGlass(prominent: true, tint: .orange)
			== Glass.regular.interactive().tint(.orange))
	}

	@Test func theControlOffersBothLevelsByTheirLabels() {
		#expect(MachmanGlassLevel.allCases.map(\.label) == ["Standard chrome", "Extra glass"])
		#expect(MachmanTheme().glass == .standard)
	}
}
