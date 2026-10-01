import Testing
import Foundation
import MachmanAPI

// A15: a system-key-capture mode this build can't name (a newer peer's) reads as .unknown,
// yet DeviceInfo keeps its spelling and encodes that back — so a client editing the display's
// resolution returns the newer mode unchanged, and "unknown" is never invented on the wire.
struct SystemKeyCaptureEchoTests {
	private func encode(_ device: DeviceInfo) throws -> String {
		String(decoding: try MachmanWire.encoder().encode(device), as: UTF8.self)
	}

	private func decode(_ json: String) throws -> DeviceInfo {
		try MachmanWire.decoder().decode(DeviceInfo.self, from: Data(json.utf8))
	}

	@Test func editingAnotherSettingEchoesANewerMode() throws {
		var device = try decode(
			#"{"displayWidthPixels":1920,"kind":"graphics","systemKeyCapture":"whenFocused"}"#)
		#expect(device.systemKeyCapture == .unknown)
		device.displayWidthPixels = 2560
		#expect(try encode(device)
			== #"{"displayWidthPixels":2560,"enabled":true,"kind":"graphics","#
				+ #""systemKeyCapture":"whenFocused"}"#)
	}

	// The 1.0.10 spelling of the same echo: an older daemon serves "unknown" itself and keeps
	// its stored mode when it gets "unknown" back — so it round-trips untouched.
	@Test func anOlderDaemonsUnknownRoundTrips() throws {
		let device = try decode(#"{"kind":"graphics","systemKeyCapture":"unknown"}"#)
		#expect(device.systemKeyCapture == .unknown)
		#expect(try encode(device)
			== #"{"enabled":true,"kind":"graphics","systemKeyCapture":"unknown"}"#)
	}

	@Test func pickingAKnownModeReplacesTheSpelling() throws {
		var device = try decode(#"{"kind":"graphics","systemKeyCapture":"whenFocused"}"#)
		device.systemKeyCapture = .always
		#expect(device == DeviceInfo(kind: .graphics, systemKeyCapture: .always))
		#expect(try encode(device)
			== #"{"enabled":true,"kind":"graphics","systemKeyCapture":"always"}"#)
		device.systemKeyCapture = nil
		#expect(try encode(device) == #"{"enabled":true,"kind":"graphics"}"#)
	}

	// Re-selecting the unknown row (the picker's own echo) keeps the spelling.
	@Test func reassigningUnknownKeepsTheSpelling() throws {
		var device = try decode(#"{"kind":"graphics","systemKeyCapture":"whenFocused"}"#)
		device.systemKeyCapture = .unknown
		#expect(device.systemKeyCaptureSpelling == "whenFocused")
	}

	@Test func unknownWithoutASpellingIsLeftOffTheWire() throws {
		#expect(try encode(DeviceInfo(kind: .graphics, systemKeyCapture: .unknown))
			== #"{"enabled":true,"kind":"graphics"}"#)
	}

	@Test func spellingSetterMapsKnownModes() {
		var device = DeviceInfo(kind: .graphics)
		device.systemKeyCaptureSpelling = "fullScreen"
		#expect(device == DeviceInfo(kind: .graphics, systemKeyCapture: .fullScreen))
		device.systemKeyCaptureSpelling = "whenFocused"
		#expect(device.systemKeyCapture == .unknown)
		#expect(device.systemKeyCaptureSpelling == "whenFocused")
		device.systemKeyCaptureSpelling = nil
		#expect(device == DeviceInfo(kind: .graphics))
	}
}
