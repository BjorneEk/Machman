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
import SwiftUI
import Virtualization
import MachmanAPI

// The vmhost's application object. VZVirtualMachineView runs its own local key monitor
// (its _keyEventMonitor ivar) that swallows every key while the view has focus — a monitor
// of ours never saw the reserved chords (2026-09-26), and neither did menu key equivalents.
// AppKit dispatches local monitors from inside NSApplication.sendEvent, so an override that
// acts before calling super comes first.
final class VMHostApplication: NSApplication {
	// true = the event was Machman's and is consumed.
	var keyInterceptor: (@MainActor (NSEvent) -> Bool)?

	override func sendEvent(_ event: NSEvent) {
		if event.type == .keyDown || event.type == .keyUp, keyInterceptor?(event) == true {
			return
		}
		super.sendEvent(event)
	}
}

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

	// Full-screen chrome: while capturing, the host Dock and menu bar are HIDDEN so they never
	// slide in over the guest's own; otherwise they auto-hide (the AppKit default). An invalid
	// combination makes AppKit raise — which would take the vmhost and its VM down — so this
	// only ever swaps the Dock/menu-bar flags and keeps the documented rules: hideMenuBar
	// needs hideDock, and autoHideToolbar needs autoHideMenuBar.
	static func fullScreenOptions(
		_ base: NSApplication.PresentationOptions, capturing: Bool
	) -> NSApplication.PresentationOptions {
		var options = base
		options.subtract([.autoHideDock, .hideDock, .autoHideMenuBar, .hideMenuBar])
		if capturing {
			options.subtract(.autoHideToolbar)
			options.formUnion([.hideDock, .hideMenuBar])
		} else {
			options.formUnion([.autoHideDock, .autoHideMenuBar])
		}
		options.insert(.fullScreen)
		return options
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

// A short message over the VM display whenever capture flips — in full screen the hidden
// menu bar leaves no other sign of where the keys go.
@MainActor
final class KeyCaptureStatus: ObservableObject {
	@Published private(set) var message: String?
	private var hideTask: Task<Void, Never>?

	func show(_ message: String) {
		self.message = message
		hideTask?.cancel()
		hideTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(2.5))
			guard !Task.isCancelled else { return }
			self?.message = nil
		}
	}
}

struct KeyCaptureToast: View {
	@ObservedObject var status: KeyCaptureStatus

	var body: some View {
		ZStack {
			if let message = status.message {
				Text(message)
					.font(.system(size: 13, weight: .medium))
					.padding(.horizontal, 14)
					.padding(.vertical, 7)
					.background(.regularMaterial, in: Capsule())
					.padding(.top, 12)
					.transition(.opacity)
			}
		}
		.animation(.easeInOut(duration: 0.2), value: status.message)
		.allowsHitTesting(false)
	}
}

// One per VM window. Owns nothing about the run: the mode is read and written through the
// presenter, which resolves the window's CURRENT VM name (safeSave renames mid-run).
@MainActor
final class KeyCaptureController {
	let window: NSWindow
	let status = KeyCaptureStatus()
	private weak var view: VZVirtualMachineView?
	private let readMode: () -> SystemKeyCapture
	private let writeMode: (SystemKeyCapture) -> Void
	// Full screen as capture sees it: set once the transition has finished, cleared as soon
	// as the exit begins — Full Screen Only releases at the start of the way out.
	private(set) var inFullScreen = false
	private(set) var isCapturing = false
	private var loggedMode: SystemKeyCapture?
	// The key of a chord we consumed: its key-up is consumed too, so the guest never sees a
	// release without a press.
	private var consumedKeyCode: UInt16?
	// Main-menu shortcuts parked while capturing, so ⌘Q/⌘W reach the guest too.
	private var parkedKeyEquivalents: [(NSMenuItem, String, NSEvent.ModifierFlags)] = []

	init(
		window: NSWindow, mode: @escaping () -> SystemKeyCapture,
		setMode: @escaping (SystemKeyCapture) -> Void
	) {
		self.window = window
		self.readMode = mode
		self.writeMode = setMode
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

	// What the window enters full screen with: hidden Dock and menu bar if this run captures
	// there, the proposal untouched otherwise.
	func fullScreenPresentationOptions(
		proposed: NSApplication.PresentationOptions
	) -> NSApplication.PresentationOptions {
		KeyCapturePolicy.isCapturing(mode: mode, fullScreen: true)
			? KeyCapturePolicy.fullScreenOptions(proposed, capturing: true) : proposed
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

	// Belt: full screen is over, so no hidden-Dock/menu-bar option may outlive it.
	func windowDidExitFullScreen() {
		if !NSApp.presentationOptions.isEmpty {
			NSApp.presentationOptions = []
		}
	}

	func windowDidFailToEnterFullScreen() {
		inFullScreen = false
		refresh(cause: "full screen failed")
	}

	// The window is going away: never leave a dangling capture or parked menu.
	func tearDown() {
		view?.capturesSystemKeys = false
		isCapturing = false
		restoreKeyEquivalents()
	}

	// Called from VMHostApplication.sendEvent for this window's key events, ahead of VZ's own
	// monitor and the menus. Returns true when the event was a reserved chord (or its
	// release) and is consumed; held keys are consumed without repeating the action.
	func interceptKey(_ event: NSEvent) -> Bool {
		if event.type == .keyUp {
			guard event.keyCode == consumedKeyCode else { return false }
			consumedKeyCode = nil
			return true
		}
		guard let key = KeyCapturePolicy.reservedKey(
			characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
		else {
			return false
		}
		consumedKeyCode = event.keyCode
		if !event.isARepeat {
			perform(key)
		}
		return true
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
		let flipped = capturing != isCapturing
		guard flipped || mode != loggedMode else { return }
		isCapturing = capturing
		loggedMode = mode
		MachmanLogger.log(.log, "key capture: \(window.title) mode=\(mode.rawValue) "
			+ "capturing=\(capturing) (\(cause))")
		applyFullScreenChrome(capturing: capturing)
		if flipped {
			status.show(capturing ? "System keys → guest · ⌃⌥⌘K releases" : "System keys → Mac")
		}
	}

	// A capture change INSIDE full screen swaps the Dock/menu-bar options live. Only between
	// didEnter and willExit (inFullScreen) and only while AppKit itself reports full screen —
	// never mid-transition, where AppKit owns the options.
	private func applyFullScreenChrome(capturing: Bool) {
		let current = NSApp.presentationOptions
		guard inFullScreen, current.contains(.fullScreen) else { return }
		let options = KeyCapturePolicy.fullScreenOptions(current, capturing: capturing)
		guard options != current else { return }
		NSApp.presentationOptions = options
		MachmanLogger.log(.log, "key capture: \(window.title) full-screen chrome "
			+ (capturing ? "hidden" : "auto-hide"))
	}
}
