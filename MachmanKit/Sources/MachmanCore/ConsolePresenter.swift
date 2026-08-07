//
//  ConsolePresenter.swift
//  Machman
//
//  Owns console windows and their capture. This is the one component that can never move to a
//  client process: VZVirtualMachineView must live in the process that owns the VZVirtualMachine,
//  so windows are presented here, engine-side, and clients only send commands about them.
//
//  Closing a window prompts: Close Window (VM keeps running) / Shut Down (ask the guest, with a
//  force-stop offer if it doesn't comply) / Force Stop / Cancel. dropConsole closes
//  programmatically and never prompts (the VM already went away).
//

import AppKit
import SwiftUI
import Virtualization
import ScreenCaptureKit
import MachmanAPI

@MainActor
final class ConsolePresenter: NSObject, NSWindowDelegate {
	private var windows: [String: NSWindow] = [:]
	// Injected by the registry: how to stop a VM, and whether it is still running.
	var stopHandler: ((String, StopMode) -> Void)?
	var isRunning: ((String) -> Bool)?
	// Fired whenever a console window appears or goes away (clients track consoleOpen).
	var onConsoleChanged: (() -> Void)?
	// Reported once when previews are unavailable, so the black thumbnail has an explanation.
	var onScreenRecordingDenied: (() -> Void)?

	private let softStopGraceSeconds: Double = 30
	// Screen Recording is asked for at most ONCE per process. Previews poll every few seconds,
	// and calling ScreenCaptureKit without the grant re-prompts every time — a stack of identical
	// dialogs every time the desktop regains focus. Note the grant is keyed to code identity, so
	// changing the bundle identifier starts over with none.
	private var didRequestScreenRecording = false

	func openConsole(name: String, vz: VZVirtualMachine) {
		if let existing = windows[name] {
			existing.makeKeyAndOrderFront(nil)
			return
		}
		let size = VMConfig.mainScreenSize(2560, 1440)
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2),
			styleMask: [.titled, .closable, .resizable],
			backing: .buffered,
			defer: false
		)
		window.center()
		window.title = name
		window.contentView = NSHostingView(rootView: VMView(vm: vz))
		window.makeKeyAndOrderFront(nil)
		window.isReleasedWhenClosed = false
		window.delegate = self
		windows[name] = window
		onConsoleChanged?()
	}

	// Close and forget without prompting (the VM went away on its own).
	func dropConsole(name: String) {
		guard let window = windows[name] else { return }
		forget(name)
		window.close()
	}

	func window(for name: String) -> NSWindow? {
		windows[name]
	}

	private func forget(_ name: String) {
		guard let window = windows[name] else { return }
		window.delegate = nil
		windows[name] = nil
		onConsoleChanged?()
	}

	// MARK: - Close prompt

	func windowShouldClose(_ sender: NSWindow) -> Bool {
		guard let name = windows.first(where: { $0.value === sender })?.key else {
			return true
		}
		guard isRunning?(name) ?? false else {
			forget(name)
			return true
		}
		let alert = NSAlert()
		alert.messageText = "\(name) is running"
		alert.informativeText = "Close the console window and leave the VM running, "
			+ "ask the guest to shut down, or stop it immediately?"
		alert.addButton(withTitle: "Close Window")
		alert.addButton(withTitle: "Shut Down")
		alert.addButton(withTitle: "Force Stop")
		alert.addButton(withTitle: "Cancel")
		switch alert.runModal() {
		case .alertFirstButtonReturn:      // Close Window — VM keeps running headless
			forget(name)
			return true
		case .alertSecondButtonReturn:     // Shut Down — window stays to watch it happen
			stopHandler?(name, .soft)
			scheduleSoftStopEscalation(name)
			return false
		case .alertThirdButtonReturn:      // Force Stop — teardown closes the window
			stopHandler?(name, .force)
			return false
		default:
			return false
		}
	}

	// If the guest ignores the shutdown request, offer force after a grace period.
	private func scheduleSoftStopEscalation(_ name: String) {
		Task { [weak self] in
			try? await Task.sleep(for: .seconds(self?.softStopGraceSeconds ?? 30))
			guard let self = self,
				self.windows[name] != nil,
				self.isRunning?(name) ?? false else {
				return
			}
			let alert = NSAlert()
			alert.messageText = "\(name) hasn't shut down yet"
			alert.informativeText = "The guest hasn't responded to the shutdown request."
			alert.addButton(withTitle: "Keep Waiting")
			alert.addButton(withTitle: "Force Stop")
			if alert.runModal() == .alertSecondButtonReturn {
				self.stopHandler?(name, .force)
			}
		}
	}

	// MARK: - Window capture (previews)

	static func blackImage(size: NSSize) -> NSImage {
		let image = NSImage(size: size)
		image.lockFocus()
		NSColor.black.setFill()
		NSRect(origin: .zero, size: size).fill()
		image.unlockFocus()
		return image
	}

	// One frame of the console window via SCScreenshotManager: a one-shot capture (no stream
	// lifecycle churning the system's recording indicator), and onScreenWindowsOnly: false +
	// desktopIndependentWindow so windows parked on other Spaces still resolve. Always returns
	// an image (black fallback). Ceiling note: any ScreenCaptureKit path shows the system
	// capture indicator and needs Screen Recording permission — the plan to escape both is the
	// private-framebuffer PreviewSource (researched, deferred).
	func captureImage(name: String) async -> NSImage {
		let fallback = Self.blackImage(size: NSSize(width: 300, height: 200))
		guard let window = windows[name] else { return fallback }
		guard hasScreenRecordingAccess() else { return fallback }
		let windowID = CGWindowID(window.windowNumber)
		guard let content = try? await SCShareableContent
			.excludingDesktopWindows(false, onScreenWindowsOnly: false),
			let target = content.windows.first(where: { $0.windowID == windowID }) else {
			return fallback
		}
		let config = SCStreamConfiguration()
		config.width = Int(target.frame.width)
		config.height = Int(target.frame.height)
		let filter = SCContentFilter(desktopIndependentWindow: target)
		guard let cgImage = try? await SCScreenshotManager.captureImage(
			contentFilter: filter, configuration: config) else {
			return fallback
		}
		return NSImage(
			cgImage: cgImage,
			size: NSSize(width: cgImage.width, height: cgImage.height))
	}

	// Preflight never prompts; request prompts once and is latched. Without this, every preview
	// poll that lands while the grant is missing raises another dialog.
	private func hasScreenRecordingAccess() -> Bool {
		if CGPreflightScreenCaptureAccess() {
			return true
		}
		guard !didRequestScreenRecording else { return false }
		didRequestScreenRecording = true
		if CGRequestScreenCaptureAccess() {
			return true
		}
		onScreenRecordingDenied?()
		return false
	}
}
