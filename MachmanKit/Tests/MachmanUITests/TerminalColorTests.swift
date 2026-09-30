import Testing
import AppKit
import MachmanAPI
import MachmanUI

struct TerminalColorTests {
	@Test func parsesSixDigitHexWithAndWithoutHash() {
		#expect(parseHexColor("#282c34") == RGB8(r: 0x28, g: 0x2c, b: 0x34))
		#expect(parseHexColor("282c34") == RGB8(r: 0x28, g: 0x2c, b: 0x34))
		#expect(parseHexColor("#FFFFFF") == RGB8(r: 255, g: 255, b: 255))
	}

	@Test func rejectsMalformedHex() {
		#expect(parseHexColor("") == nil)
		#expect(parseHexColor("#fff") == nil)          // too short
		#expect(parseHexColor("#12345g") == nil)       // non-hex digit
		#expect(parseHexColor("orange") == nil)
	}

	@Test func formatRoundTrips() {
		let c = RGB8(r: 0x61, g: 0xaf, b: 0xef)
		#expect(parseHexColor(formatHexColor(c)) == c)
	}

	@Test func nsColorFromHexMatchesComponents() throws {
		let color = try #require(NSColor(hexColor: "#61afef"))
		let srgb = try #require(color.usingColorSpace(.sRGB))
		#expect(Int((srgb.redComponent * 255).rounded()) == 0x61)
		#expect(Int((srgb.greenComponent * 255).rounded()) == 0xaf)
		#expect(Int((srgb.blueComponent * 255).rounded()) == 0xef)
	}

	@Test func presetsHaveSixteenValidAnsiEntries() {
		for theme in TerminalTheme.allCases {
			let colors = theme.colors
			#expect(colors.ansi.count == 16)
			for hex in colors.ansi { #expect(parseHexColor(hex) != nil) }
			#expect(parseHexColor(colors.foreground) != nil)
			#expect(parseHexColor(colors.background) != nil)
			#expect(parseHexColor(colors.selectionBackground) != nil)
		}
	}

	@Test func oneDarkMatchesKittyValues() {
		let c = TerminalTheme.oneDark.colors
		#expect(c.foreground == "#979eab")
		#expect(c.background == "#282c34")
		#expect(c.cursor == "#cccccc")
		#expect(c.ansi[1] == "#e06c75")
		#expect(c.ansi[15] == "#abb2bf")
	}
}
