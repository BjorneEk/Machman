//
//  KeyCaptureStateTests.swift
//  MachmanTests
//
//  Key capture's bookkeeping for one VM window (KeyCaptureState.swift): what a refresh or a
//  full-screen transition asks the controller to do, and which key events are Machman's.
//  Pure values — no window, view or VM.
//

import Testing
import MachmanAPI
@testable import MachmanCore

struct KeyCaptureStateTests {
	// Only a change is reported: the first refresh, a new mode, a capture flip.
	@Test func aRefreshReportsOnlyChanges() {
		var state = KeyCaptureState()
		let first = state.refresh(mode: .off)
		#expect(first.changed && !first.flipped && !first.capturing)

		let again = state.refresh(mode: .off)
		#expect(!again.changed && !again.flipped)

		let always = state.refresh(mode: .always)
		#expect(always.changed && always.flipped && always.capturing)
		#expect(state.isCapturing)

		let fullScreenOnly = state.refresh(mode: .fullScreen)   // windowed: releases
		#expect(fullScreenOnly.changed && fullScreenOnly.flipped && !fullScreenOnly.capturing)
	}

	// A capture flip touches the full-screen chrome only while in full screen.
	@Test func chromeIsReconciledOnlyInFullScreen() {
		var state = KeyCaptureState()
		_ = state.refresh(mode: .off)
		let windowed = state.refresh(mode: .always)
		#expect(windowed.flipped && !windowed.reconcileChrome)

		var inFull = KeyCaptureState()
		_ = inFull.refresh(mode: .always)
		_ = inFull.didEnterFullScreen(mode: .always)
		let mode = inFull.toggled(mode: .always)
		#expect(mode == .off)
		let released = inFull.refresh(mode: mode)
		#expect(released.reconcileChrome && released.flipped && !released.capturing)
	}

	// Full Screen Only captures once inside and releases as the exit begins.
	@Test func fullScreenOnlyReleasesAtTheStartOfTheExit() {
		var state = KeyCaptureState()
		_ = state.refresh(mode: .fullScreen)
		#expect(!state.isCapturing)
		let entered = state.didEnterFullScreen(mode: .fullScreen)
		#expect(entered.capturing && entered.flipped && state.inFullScreen)
		let leaving = state.willExitFullScreen(mode: .fullScreen)
		#expect(!leaving.capturing && leaving.flipped && !state.inFullScreen)
	}

	// A held chord acts once; its repeats and its own release are Machman's too.
	@Test func aHeldChordIsConsumedWithItsRelease() {
		var state = KeyCaptureState()
		#expect(state.keyDown(keyCode: 40, reserved: .toggleCapture, isRepeat: false)
			== .perform(.toggleCapture))
		#expect(state.keyDown(keyCode: 40, reserved: .toggleCapture, isRepeat: true)
			== .consume)
		#expect(state.keyUp(keyCode: 3) == .pass)      // another key's release: the guest's
		#expect(state.keyUp(keyCode: 40) == .consume)
		#expect(state.keyUp(keyCode: 40) == .pass)     // consumed once, then the guest's
	}

	@Test func ordinaryKeysPass() {
		var state = KeyCaptureState()
		#expect(state.keyDown(keyCode: 3, reserved: nil, isRepeat: false) == .pass)
		#expect(state.keyUp(keyCode: 3) == .pass)
	}

	@Test func tearDownReleases() {
		var state = KeyCaptureState()
		_ = state.refresh(mode: .always)
		#expect(state.isCapturing)
		state.tearDown()
		#expect(!state.isCapturing)
	}
}
