import Testing
import MachmanAPI
@testable import MachmanCore

// System key capture decisions (KeyCapture.swift) — pure, so no window or VM involved.
struct KeyCapturePolicyTests {

	@Test func capturingFollowsModeAndFullScreen() {
		let cases: [(SystemKeyCapture, Bool, Bool)] = [
			(.off, false, false), (.off, true, false),
			(.always, false, true), (.always, true, true),
			(.fullScreen, false, false), (.fullScreen, true, true),
			(.unknown, false, false), (.unknown, true, false),   // a newer mode counts as off
		]
		for (mode, fullScreen, expected) in cases {
			#expect(
				KeyCapturePolicy.isCapturing(mode: mode, fullScreen: fullScreen) == expected,
				"\(mode) fullScreen=\(fullScreen)")
		}
	}

	// ⌃⌥⌘K: capturing → off; otherwise the narrowest capture that works right now.
	@Test func toggleIsNarrowest() {
		let cases: [(SystemKeyCapture, Bool, SystemKeyCapture)] = [
			(.always, false, .off), (.always, true, .off),
			(.fullScreen, true, .off),
			(.fullScreen, false, .always),   // not capturing windowed → capture now
			(.off, false, .always),
			(.off, true, .fullScreen),       // leaving full screen will release it
			(.unknown, false, .always), (.unknown, true, .fullScreen),
		]
		for (mode, fullScreen, expected) in cases {
			#expect(
				KeyCapturePolicy.toggled(mode: mode, fullScreen: fullScreen) == expected,
				"\(mode) fullScreen=\(fullScreen)")
		}
	}

	// Toggling twice from a capturing state lands capturing again, in the same place.
	@Test func toggleRoundTripsCapture() {
		for fullScreen in [false, true] {
			let off = KeyCapturePolicy.toggled(mode: .always, fullScreen: fullScreen)
			let back = KeyCapturePolicy.toggled(mode: off, fullScreen: fullScreen)
			#expect(KeyCapturePolicy.isCapturing(mode: back, fullScreen: fullScreen))
		}
	}
}
