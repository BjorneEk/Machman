import Testing
import AppKit
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

	// ⌃⌥⌘K / ⌃⌥⌘F stay Machman's: exactly ⌃⌥⌘ (caps lock and fn don't matter), any case.
	@Test func reservedKeysNeedExactlyControlOptionCommand() {
		let chord: NSEvent.ModifierFlags = [.control, .option, .command]
		#expect(KeyCapturePolicy.reservedKey(characters: "k", modifiers: chord)
			== .toggleCapture)
		#expect(KeyCapturePolicy.reservedKey(characters: "f", modifiers: chord)
			== .toggleFullScreen)
		#expect(KeyCapturePolicy.reservedKey(characters: "K", modifiers: chord)
			== .toggleCapture)
		#expect(KeyCapturePolicy.reservedKey(
			characters: "k", modifiers: chord.union([.capsLock, .function]))
			== .toggleCapture)

		#expect(KeyCapturePolicy.reservedKey(
			characters: "k", modifiers: chord.union(.shift)) == nil)
		#expect(KeyCapturePolicy.reservedKey(characters: "k", modifiers: .command) == nil)
		#expect(KeyCapturePolicy.reservedKey(
			characters: "f", modifiers: [.control, .command]) == nil)   // ⌃⌘F: guest's
		#expect(KeyCapturePolicy.reservedKey(characters: "q", modifiers: chord) == nil)
		#expect(KeyCapturePolicy.reservedKey(characters: nil, modifiers: chord) == nil)
	}

	// V3: a key press matches on the layout's ⌘ layer, which the fake translator plays here.
	@Test @MainActor func reservedChordsMatchTheCommandLayer() {
		let chord: NSEvent.ModifierFlags = [.control, .option, .command]
		func key(_ code: UInt16, _ characters: String?, command: String?)
			-> KeyCapturePolicy.ReservedKey? {
			KeyCapturePolicy.reservedKey(
				keyCode: code, characters: characters, modifiers: chord,
				commandCharacter: { _ in command })
		}
		#expect(key(40, "л", command: "k") == .toggleCapture)        // Russian
		#expect(key(3, "φ", command: "f") == .toggleFullScreen)      // Greek
		#expect(key(40, "t", command: "k") == .toggleCapture)        // Dvorak – QWERTY ⌘, K
		#expect(key(9, "k", command: "v") == nil)                    // …its Dvorak-K key
		#expect(key(40, "k", command: nil) == .toggleCapture)        // no layout data

		// The bug: the event's characters alone miss the chord on a Cyrillic layout.
		#expect(KeyCapturePolicy.reservedKey(characters: "л", modifiers: chord) == nil)
	}

	// Text Input Sources is asked only for an exact ⌃⌥⌘ press.
	@Test @MainActor func theLayoutIsAskedOnlyForTheChord() {
		var calls = 0
		let translate: @MainActor (UInt16) -> String? = { _ in calls += 1; return "k" }
		for modifiers: NSEvent.ModifierFlags in [
			.command, [.control, .command], [.option, .command],
			[.control, .option, .command, .shift],
		] {
			#expect(KeyCapturePolicy.reservedKey(
				keyCode: 40, characters: "k", modifiers: modifiers,
				commandCharacter: translate) == nil)
		}
		#expect(calls == 0)
		#expect(KeyCapturePolicy.reservedKey(
			keyCode: 40, characters: "k", modifiers: [.control, .option, .command],
			commandCharacter: translate) == .toggleCapture)
		#expect(calls == 1)
	}

	// The menus show the same chords the monitor matches — one source for both.
	@Test @MainActor func menuItemsCarryTheReservedChords() {
		let fullScreen = KeyCaptureMenu.fullScreenItem()
		#expect(KeyCapturePolicy.reservedKey(
			characters: fullScreen.keyEquivalent,
			modifiers: fullScreen.keyEquivalentModifierMask) == .toggleFullScreen)
		let keyboard = KeyCaptureMenu.keyboardMenuItem(target: WindowPresenter())
		let toggle = keyboard.submenu?.items.first {
			$0.action == #selector(WindowPresenter.toggleCapture(_:))
		}
		#expect(toggle.map {
			KeyCapturePolicy.reservedKey(
				characters: $0.keyEquivalent, modifiers: $0.keyEquivalentModifierMask)
		} == .toggleCapture)
	}

	// AppKit's documented presentation-option rules — an invalid set raises, which would
	// take the vmhost (and its VM) down, so every output must satisfy all of them.
	private func isValid(_ o: NSApplication.PresentationOptions) -> Bool {
		let dock: NSApplication.PresentationOptions = [.autoHideDock, .hideDock]
		let needsDock: NSApplication.PresentationOptions = [
			.disableProcessSwitching, .disableForceQuit, .disableSessionTermination,
			.disableMenuBarTransparency,
		]
		if o.contains(dock) || o.contains([.autoHideMenuBar, .hideMenuBar]) { return false }
		if o.contains(.hideMenuBar), !o.contains(.hideDock) { return false }
		if o.contains(.autoHideMenuBar), o.isDisjoint(with: dock) { return false }
		if !o.isDisjoint(with: needsDock), o.isDisjoint(with: dock) { return false }
		if o.contains(.autoHideToolbar), !o.contains([.fullScreen, .autoHideMenuBar]) {
			return false
		}
		return true
	}

	@Test func fullScreenOptionsStayValidBothWays() {
		let appKitDefault: NSApplication.PresentationOptions =
			[.fullScreen, .autoHideDock, .autoHideMenuBar]
		let bases: [NSApplication.PresentationOptions] = [
			appKitDefault,
			appKitDefault.union(.autoHideToolbar),
			appKitDefault.union(.disableMenuBarTransparency),
			[.fullScreen, .hideDock, .hideMenuBar],   // our own capturing set, released
		]
		for base in bases {
			let hidden = KeyCapturePolicy.fullScreenOptions(base, capturing: true)
			#expect(isValid(hidden), "capturing from \(base.rawValue)")
			#expect(hidden.contains([.fullScreen, .hideDock, .hideMenuBar]))

			let shown = KeyCapturePolicy.fullScreenOptions(base, capturing: false)
			#expect(isValid(shown), "released from \(base.rawValue)")
			#expect(shown.contains([.fullScreen, .autoHideDock, .autoHideMenuBar]))

			// Live toggling back and forth never drifts from those two sets.
			let again = KeyCapturePolicy.fullScreenOptions(shown, capturing: true)
			#expect(again == hidden.subtracting(.autoHideToolbar))
		}
		// Released from AppKit's own default is exactly that default.
		#expect(KeyCapturePolicy.fullScreenOptions(appKitDefault, capturing: false)
			== appKitDefault)
	}
}
