import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// The display inspector's pickers (H14, A15) and the edit flow behind them.
@MainActor
struct GraphicsChoicesTests {
	// H14: presets are keyed by both dimensions — the old key, the width alone, repeats.
	@Test func resolutionPresetIDsAreUnique() {
		let presets = GraphicsChoices.resolutionPresets(hostWidth: 2560, hostHeight: 1664)
		#expect(Set(presets.map(\.id)).count == presets.count)
		#expect(Set(presets.map(\.width)).count < presets.count)
		#expect(presets.first == DisplayResolutionPreset(width: 2560, height: 1664))
	}

	@Test func aHostDisplayMatchingAPresetIsListedOnce() {
		let presets = GraphicsChoices.resolutionPresets(hostWidth: 3024, hostHeight: 1964)
		#expect(presets.map(\.id).filter { $0 == "3024x1964" }.count == 1)
		#expect(presets.first?.id == "3024x1964")
		#expect(GraphicsChoices.resolutionPresets(hostWidth: nil, hostHeight: nil)
			== GraphicsChoices.commonResolutions)
	}
}
