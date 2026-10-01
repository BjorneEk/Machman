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

	// A15: the unknown row exists exactly while the device holds a newer mode.
	@Test func captureRowsOfferANewerModeOnlyWhileHeld() {
		#expect(GraphicsChoices.captureModes(current: .unknown)
			== [.off, .always, .fullScreen, .unknown])
		for current: SystemKeyCapture? in [nil, .off, .always, .fullScreen] {
			#expect(GraphicsChoices.captureModes(current: current) == [.off, .always, .fullScreen])
		}
	}

	// A15: resizing a display whose capture mode came from a newer Machman sends that mode
	// back in its own spelling, so the daemon keeps it.
	@Test func resizingKeepsANewerCaptureMode() async throws {
		let vm = Samples.linuxNewerCaptureMode("Alpine")
		let h = await DesktopHarness.make([vm])
		var graphics = try #require(vm.devices?.first { $0.kind == .graphics })
		graphics.displayWidthPixels = 2560
		graphics.displayHeightPixels = 1600
		h.viewModel.updateDevice(vm.name, device: graphics)
		#expect(await eventually { h.stub.calls.contains("updateDevice") })
		let sent = try #require(h.stub.vms[vm.name]?.devices?.first { $0.kind == .graphics })
		let json = String(decoding: try MachmanWire.encoder().encode(sent), as: UTF8.self)
		#expect(json.contains(#""systemKeyCapture":"whenFocused""#))
		#expect(json.contains(#""displayWidthPixels":2560"#))
	}
}
