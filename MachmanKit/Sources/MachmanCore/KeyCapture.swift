//
//  KeyCapture.swift
//  MachmanCore
//
//  System key capture for a VM window: whether shortcuts like ⌘Space, ⌘Tab and Mission
//  Control reach the guest (VZVirtualMachineView.capturesSystemKeys) instead of the host.
//  A run starts with the display device's default (VMConfig.systemKeyCaptureDefault); the
//  run's own value lives on VMRuntime, and only the VM window's menu and hotkeys change it —
//  never the default. vmhost-only: every piece here is per process, which is per VM there.
//

import AppKit
import Virtualization
import MachmanAPI

// The decisions, pure so they are testable without a window or a VM.
enum KeyCapturePolicy {
	// VZ additionally honors capture only while its view is first responder in the key
	// window — this is whether we ASK for it.
	static func isCapturing(mode: SystemKeyCapture, fullScreen: Bool) -> Bool {
		switch mode {
		case .always: return true
		case .fullScreen: return fullScreen
		case .off, .unknown: return false
		}
	}

	// The capture toggle: release when capturing; otherwise capture the narrowest way that
	// works right now — full screen only while in full screen (so leaving it releases),
	// always while windowed.
	static func toggled(mode: SystemKeyCapture, fullScreen: Bool) -> SystemKeyCapture {
		if isCapturing(mode: mode, fullScreen: fullScreen) {
			return .off
		}
		return fullScreen ? .fullScreen : .always
	}

	// The keys Machman keeps for itself, captured or not: ⌃⌥⌘ + a letter, a chord no system
	// shortcut uses. Matched on characters (like menu key equivalents, so it follows the
	// keyboard layout) with exactly ⌃⌥⌘ held — Shift makes it a different chord.
	enum ReservedKey: CaseIterable {
		case toggleCapture      // ⌃⌥⌘K
		case toggleFullScreen   // ⌃⌥⌘F — the way out when capture holds ⌃⌘F

		var keyEquivalent: String {
			switch self {
			case .toggleCapture: return "k"
			case .toggleFullScreen: return "f"
			}
		}
	}

	static let reservedModifiers: NSEvent.ModifierFlags = [.control, .option, .command]

	static func reservedKey(characters: String?, modifiers: NSEvent.ModifierFlags)
		-> ReservedKey? {
		let chord = modifiers.intersection([.control, .option, .command, .shift])
		guard chord == reservedModifiers, let characters = characters?.lowercased() else {
			return nil
		}
		return ReservedKey.allCases.first { $0.keyEquivalent == characters }
	}
}

// The vmhost's menu items for capture: View's full-screen item and the Keyboard menu. Their
// actions route through the presenter to the key window's controller.
@MainActor
enum KeyCaptureMenu {
	static func fullScreenItem() -> NSMenuItem {
		// nil target: the responder chain reaches the key window, and AppKit retitles the
		// item Enter/Exit Full Screen on its own.
		let item = NSMenuItem(
			title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
			keyEquivalent: KeyCapturePolicy.ReservedKey.toggleFullScreen.keyEquivalent)
		item.keyEquivalentModifierMask = KeyCapturePolicy.reservedModifiers
		return item
	}

	static func keyboardMenuItem(target: WindowPresenter) -> NSMenuItem {
		let item = NSMenuItem()
		let menu = NSMenu(title: "Keyboard")
		item.submenu = menu
		menu.addItem(NSMenuItem.sectionHeader(title: "Capture System Keys"))
		let modes: [(String, SystemKeyCapture)] = [
			("Off", .off), ("Always", .always), ("In Full Screen", .fullScreen),
		]
		for (title, mode) in modes {
			let modeItem = NSMenuItem(
				title: title, action: #selector(WindowPresenter.selectCaptureMode(_:)),
				keyEquivalent: "")
			modeItem.representedObject = mode.rawValue
			modeItem.target = target
			menu.addItem(modeItem)
		}
		menu.addItem(.separator())
		let toggle = NSMenuItem(
			title: "Capture System Keys", action: #selector(WindowPresenter.toggleCapture(_:)),
			keyEquivalent: KeyCapturePolicy.ReservedKey.toggleCapture.keyEquivalent)
		toggle.keyEquivalentModifierMask = KeyCapturePolicy.reservedModifiers
		toggle.target = target
		menu.addItem(toggle)
		return item
	}
}

// One per VM window. Owns nothing about the run: the mode is read and written through the
// presenter, which resolves the window's CURRENT VM name (safeSave renames mid-run).
@MainActor
final class KeyCaptureController {
	let window: NSWindow
	private weak var view: VZVirtualMachineView?
	private let readMode: () -> SystemKeyCapture
	private let writeMode: (SystemKeyCapture) -> Void
	// Full screen as capture sees it: set once the transition has finished, cleared as soon
	// as the exit begins — Full Screen Only releases at the start of the way out.
	private(set) var inFullScreen = false
	private(set) var isCapturing = false
	private var loggedMode: SystemKeyCapture?
	private var keyMonitor: Any?
	// Main-menu shortcuts parked while capturing, so ⌘Q/⌘W reach the guest too.
	private var parkedKeyEquivalents: [(NSMenuItem, String, NSEvent.ModifierFlags)] = []

	init(
		window: NSWindow, mode: @escaping () -> SystemKeyCapture,
		setMode: @escaping (SystemKeyCapture) -> Void
	) {
		self.window = window
		self.readMode = mode
		self.writeMode = setMode
		installKeyMonitor()
	}

	var mode: SystemKeyCapture { readMode() }

	// The VZ view arrives once SwiftUI has made it (VirtualMachineView.onCreate).
	func attach(_ view: VZVirtualMachineView) {
		self.view = view
		refresh(cause: "window opened")
	}

	func setMode(_ mode: SystemKeyCapture, cause: String) {
		writeMode(mode)
		refresh(cause: cause)
	}

	func toggle(cause: String) {
		setMode(KeyCapturePolicy.toggled(mode: mode, fullScreen: inFullScreen), cause: cause)
	}

	func windowDidBecomeKey() {
		focusView()
	}

	func windowDidEnterFullScreen() {
		inFullScreen = true
		focusView()
		refresh(cause: "entered full screen")
	}

	func windowWillExitFullScreen() {
		inFullScreen = false
		refresh(cause: "leaving full screen")
	}

	func windowDidFailToEnterFullScreen() {
		inFullScreen = false
		refresh(cause: "full screen failed")
	}

	// The window is going away: never leave a dangling capture, monitor or parked menu.
	func tearDown() {
		view?.capturesSystemKeys = false
		isCapturing = false
		restoreKeyEquivalents()
		if let keyMonitor {
			NSEvent.removeMonitor(keyMonitor)
		}
		keyMonitor = nil
	}

	// A local monitor sees each key event inside NSApplication.sendEvent, before the window,
	// its VZ view or the menus do — so the reserved chords stay Machman's even while VZ
	// captures. Held keys are swallowed without repeating the action.
	private func installKeyMonitor() {
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			MainActor.assumeIsolated {
				guard let self, event.window === self.window,
					let key = KeyCapturePolicy.reservedKey(
						characters: event.charactersIgnoringModifiers,
						modifiers: event.modifierFlags)
				else {
					return event
				}
				if !event.isARepeat {
					self.perform(key)
				}
				return nil
			}
		}
	}

	private func perform(_ key: KeyCapturePolicy.ReservedKey) {
		switch key {
		case .toggleCapture:
			toggle(cause: "⌃⌥⌘K")
		case .toggleFullScreen:
			// Outside the event dispatch: the transition runs its own event loop.
			DispatchQueue.main.async { [weak window] in
				window?.toggleFullScreen(nil)
			}
		}
	}

	private func parkKeyEquivalents() {
		guard parkedKeyEquivalents.isEmpty, let menu = NSApp.mainMenu else { return }
		for item in Self.items(in: menu) where !item.keyEquivalent.isEmpty
			&& KeyCapturePolicy.reservedKey(
				characters: item.keyEquivalent,
				modifiers: item.keyEquivalentModifierMask) == nil {
			parkedKeyEquivalents.append(
				(item, item.keyEquivalent, item.keyEquivalentModifierMask))
			item.keyEquivalent = ""
		}
	}

	private func restoreKeyEquivalents() {
		for (item, keyEquivalent, modifiers) in parkedKeyEquivalents {
			item.keyEquivalent = keyEquivalent
			item.keyEquivalentModifierMask = modifiers
		}
		parkedKeyEquivalents = []
	}

	private static func items(in menu: NSMenu) -> [NSMenuItem] {
		menu.items.flatMap { item in [item] + (item.submenu.map(items(in:)) ?? []) }
	}

	// VZ captures only while its view is first responder in the key window.
	private func focusView() {
		guard let view, window.firstResponder !== view else { return }
		window.makeFirstResponder(view)
	}

	private func refresh(cause: String) {
		let mode = self.mode
		let capturing = KeyCapturePolicy.isCapturing(mode: mode, fullScreen: inFullScreen)
		view?.capturesSystemKeys = capturing
		if capturing {
			parkKeyEquivalents()
		} else {
			restoreKeyEquivalents()
		}
		guard capturing != isCapturing || mode != loggedMode else { return }
		isCapturing = capturing
		loggedMode = mode
		MachmanLogger.log(.log, "key capture: \(window.title) mode=\(mode.rawValue) "
			+ "capturing=\(capturing) (\(cause))")
	}
}
