//
//  DeviceLabelTests.swift
//  MachmanTests
//
//  The device and capture-mode labels live in MachmanAPI (W3, W4): the UI and the engine's
//  refusals name a device the same way, and a newer Machman's kind shows its own spelling.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI

struct DeviceLabelTests {
	@Test func kindsReadTheirLabels() {
		#expect(DeviceKind.audioInput.displayLabel == "Mic")
		#expect(DeviceKind.guestSetup.displayLabel == "Guest Setup")
		#expect(DeviceKind.displayLabel(raw: "graphics") == "Display")
		#expect(DeviceKind.displayLabel(raw: "future") == "\u{201C}future\u{201D}")
	}

	@Test func captureModesReadTheirLabels() {
		#expect(SystemKeyCapture.off.displayLabel == "Off")
		#expect(SystemKeyCapture.always.displayLabel == "Always")
		#expect(SystemKeyCapture.fullScreen.displayLabel == "In Full Screen")
		#expect(SystemKeyCapture.unknown.displayLabel == "Newer Mode")
	}
}
