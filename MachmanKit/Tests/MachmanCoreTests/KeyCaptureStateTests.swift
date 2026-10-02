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

	// V2: ⌃⌥⌘K during the entry animation. The entry's chrome was chosen from the mode at
	// willUseFullScreenPresentationOptions; the flip lands while AppKit owns the options, so
	// the end of the entry must bring the chrome in line — both ways.
	@Test(arguments: [SystemKeyCapture.always, .off])
	func aCaptureFlipMidEntryIsReconciledWhenEntryEnds(start: SystemKeyCapture) {
		var state = KeyCaptureState()
		_ = state.refresh(mode: start)
		let entryHidesChrome = KeyCapturePolicy.isCapturing(mode: start, fullScreen: true)
		let flipped = state.toggled(mode: start)             // mid-animation: still windowed
		_ = state.refresh(mode: flipped)
		let entered = state.didEnterFullScreen(mode: flipped)
		#expect(entered.reconcileChrome)
		#expect(entered.capturing == !entryHidesChrome)
	}

	// Every mash of ⌃⌥⌘K and ⌃⌥⌘F (K8) up to six steps, from each mode: whenever the window
	// sits in full screen, the Dock and menu bar are hidden exactly when capture is on.
	@Test func everyMashEndsWithTheChromeCaptureAsksFor() {
		var failures: [String] = []
		for start in [SystemKeyCapture.off, .always, .fullScreen] {
			for sequence in ChromeMash.sequences(upTo: 6) {
				var run = ChromeMash(mode: start)
				for step in sequence {
					run.step(step)
					if run.phase == .fullScreen, run.chromeHidden != run.state.isCapturing {
						failures.append("\(start): "
							+ sequence.map { "\($0)" }.joined(separator: " → "))
						break
					}
				}
			}
		}
		let count = failures.count
		#expect(count == 0, "first: \(failures.prefix(3).joined(separator: "; "))")
	}
}

// A VM window's full-screen life as AppKit drives it, with the chrome the Dock and menu bar
// actually show: chosen at entry, then changed only through the effects' reconcile.
private struct ChromeMash {
	enum Phase { case windowed, entering, fullScreen, exiting }
	enum Step: CaseIterable { case toggle, fullScreenKey, animationEnds, entryFails }

	var state = KeyCaptureState()
	var mode: SystemKeyCapture
	var phase = Phase.windowed
	var chromeHidden: Bool?

	init(mode: SystemKeyCapture) {
		self.mode = mode
		_ = state.refresh(mode: mode)   // the window opened
	}

	mutating func step(_ step: Step) {
		switch (step, phase) {
		case (.toggle, _):
			mode = state.toggled(mode: mode)
			apply(state.refresh(mode: mode))
		case (.fullScreenKey, .windowed):
			// willUseFullScreenPresentationOptions: the entry's chrome, from the mode now.
			chromeHidden = KeyCapturePolicy.isCapturing(mode: mode, fullScreen: true)
			phase = .entering
		case (.fullScreenKey, .fullScreen):
			phase = .exiting
			apply(state.willExitFullScreen(mode: mode))
		case (.animationEnds, .entering):
			phase = .fullScreen
			apply(state.didEnterFullScreen(mode: mode))
		case (.animationEnds, .exiting):
			phase = .windowed
			chromeHidden = nil
		case (.entryFails, .entering):
			phase = .windowed
			chromeHidden = nil
			apply(state.didFailToEnterFullScreen(mode: mode))
		default:
			break   // AppKit ignores the key mid-transition; nothing else applies
		}
	}

	// applyFullScreenChrome acts only while AppKit reports full screen.
	private mutating func apply(_ effects: KeyCaptureState.Effects) {
		if effects.reconcileChrome, phase == .fullScreen {
			chromeHidden = effects.capturing
		}
	}

	static func sequences(upTo length: Int) -> [[Step]] {
		var all: [[Step]] = [[]]
		var frontier: [[Step]] = [[]]
		for _ in 0..<length {
			frontier = frontier.flatMap { prefix in Step.allCases.map { prefix + [$0] } }
			all += frontier
		}
		return all
	}
}
