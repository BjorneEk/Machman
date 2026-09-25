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

	// The window is going away: never leave a dangling capture behind.
	func tearDown() {
		view?.capturesSystemKeys = false
		isCapturing = false
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
		guard capturing != isCapturing || mode != loggedMode else { return }
		isCapturing = capturing
		loggedMode = mode
		MachmanLogger.log(.log, "key capture: \(window.title) mode=\(mode.rawValue) "
			+ "capturing=\(capturing) (\(cause))")
	}
}
