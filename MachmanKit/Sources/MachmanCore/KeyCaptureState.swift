//
//  KeyCaptureState.swift
//  MachmanCore
//
//  Key capture's bookkeeping for one VM window, as a value: where capture stands, what a mode
//  change or a full-screen transition asks for, and which key events are Machman's. The
//  controller (KeyCapture.swift) carries the effects out on the VZ view, the menus and the
//  full-screen options; this stays pure so the rules are testable without a window or a VM.
//

import Foundation
import MachmanAPI

struct KeyCaptureState {
	// Full screen as capture sees it: set once the transition has finished, cleared as soon
	// as the exit begins — Full Screen Only releases at the start of the way out.
	private(set) var inFullScreen = false
	private(set) var isCapturing = false
	// The mode last reported, so a refresh with nothing new stays quiet.
	private var reportedMode: SystemKeyCapture?
	// The key of a chord we consumed: its key-up is consumed too, so the guest never sees a
	// release without a press.
	private var consumedKeyCode: UInt16?

	// What a refresh asks of the controller.
	struct Effects: Equatable {
		var capturing: Bool         // what the VZ view should ask for
		var changed: Bool           // the mode or the capture changed: log it
		var flipped: Bool           // capture itself flipped: tell the user
		var reconcileChrome: Bool   // make the full-screen Dock/menu-bar options follow
	}

	mutating func refresh(mode: SystemKeyCapture) -> Effects {
		let capturing = KeyCapturePolicy.isCapturing(mode: mode, fullScreen: inFullScreen)
		let flipped = capturing != isCapturing
		let changed = flipped || mode != reportedMode
		isCapturing = capturing
		reportedMode = mode
		return Effects(
			capturing: capturing, changed: changed, flipped: flipped,
			reconcileChrome: changed && inFullScreen)
	}

	func toggled(mode: SystemKeyCapture) -> SystemKeyCapture {
		KeyCapturePolicy.toggled(mode: mode, fullScreen: inFullScreen)
	}

	mutating func didEnterFullScreen(mode: SystemKeyCapture) -> Effects {
		inFullScreen = true
		return refresh(mode: mode)
	}

	mutating func willExitFullScreen(mode: SystemKeyCapture) -> Effects {
		inFullScreen = false
		return refresh(mode: mode)
	}

	mutating func didFailToEnterFullScreen(mode: SystemKeyCapture) -> Effects {
		inFullScreen = false
		return refresh(mode: mode)
	}

	// The window is going away.
	mutating func tearDown() {
		isCapturing = false
	}

	// What happens to a key event that reached this window.
	enum KeyAction: Equatable {
		case pass                                   // the guest's
		case consume                                // Machman's, nothing more to do
		case perform(KeyCapturePolicy.ReservedKey)  // Machman's: act on it
	}

	// reserved: the chord this press matches, if any. A held chord repeats without acting.
	mutating func keyDown(
		keyCode: UInt16, reserved: KeyCapturePolicy.ReservedKey?, isRepeat: Bool
	) -> KeyAction {
		guard let reserved else { return .pass }
		consumedKeyCode = keyCode
		return isRepeat ? .consume : .perform(reserved)
	}

	mutating func keyUp(keyCode: UInt16) -> KeyAction {
		guard keyCode == consumedKeyCode else { return .pass }
		consumedKeyCode = nil
		return .consume
	}
}
