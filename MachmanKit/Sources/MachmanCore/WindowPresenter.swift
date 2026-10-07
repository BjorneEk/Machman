//
//  WindowPresenter.swift
//  Machman
//
//  Owns VM windows and their capture. This is the one component that can never move to a
//  client process: VZVirtualMachineView must live in the process that owns the VZVirtualMachine,
//  so windows are presented here, engine-side, and clients only send commands about them.
//
//  Closing a window prompts: Close Window (VM keeps running) / Shut Down (ask the guest, with a
//  force-stop offer if it doesn't comply) / Force Stop / Cancel. dropWindow closes
//  programmatically and never prompts (the VM already went away).
//

import AppKit
import SwiftUI
import Virtualization
import ScreenCaptureKit
import MachmanAPI

@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
	private var windows: [String: NSWindow] = [:]
	// Injected by the registry: how to stop a VM (throwing what the engine refused), and
	// whether it is still running.
	var stopHandler: (@MainActor (String, StopMode) async throws -> Void)?
	var isRunning: ((String) -> Bool)?
	// Fired whenever a VM window appears or goes away (clients track windowOpen).
	var onWindowChanged: (() -> Void)?
	// Why a preview came back blank. A black thumbnail is the fallback for three quite different
	// failures, and telling them apart from the outside is impossible.
	enum CaptureFailure: Equatable {
		case noPermission
		case windowNotFound(CGWindowID)
		case captureReturnedNothing
	}
	// Reported once per distinct reason, so a poll every few seconds can't spam.
	var onCaptureFailed: ((CaptureFailure) -> Void)?
	private var reportedFailures: Set<String> = []

	// Every Shut Down this presenter asks for is followed up (SoftStopEscalation.swift).
	let softStopFollowUp = SoftStopEscalation()
	private var captureInFlight = false

	// Only the vmhost sets this: with a window open that process is a real app (Dock icon,
	// menus); windowless it drops back to accessory. The daemon's presenter must never flip
	// the menu-bar agent's LSUIElement — and there it is provably inert anyway: since the
	// vmhost split the daemon never runs a VM, so its presenter never opens a window.
	var managesActivationPolicy = false
	// vmhost-only as well: system key capture (KeyCapture.swift) — its hotkeys, menus and
	// full-screen chrome are process-wide, so only a one-VM process may own them.
	var managesKeyCapture = false
	// Injected by the registry: the run's capture mode (VMRuntime) — nil once not running.
	var captureMode: ((String) -> SystemKeyCapture?)?
	var setCaptureMode: ((String, SystemKeyCapture) -> Void)?
	// Keyed by window, not name: safeSave renames the VM under an open window.
	private var keyCaptures: [ObjectIdentifier: KeyCaptureController] = [:]

	// Under a test suite (the lab, and the headless tests) this presenter never reaches the
	// screen: it opens no window (so no Dock icon, activation or key capture), captures no
	// preview (no Screen Recording prompt) and answers its prompts from the lab's answers
	// file. nil everywhere else.
	var lab: LabEnvironment? = LabEnvironment.current
	private var reportedLabPreviews: Set<String> = []

	// Who answers a prompt: a test's seam, then the lab, then the person (an alert).
	enum PromptRoute: Equatable {
		case seam
		case lab
		case alert
	}

	nonisolated static func route(hasSeam: Bool, lab: LabEnvironment?) -> PromptRoute {
		if hasSeam { return .seam }
		return lab == nil ? .alert : .lab
	}

	nonisolated static func opensWindows(lab: LabEnvironment?) -> Bool {
		lab == nil
	}

	nonisolated static func capturesPreviews(lab: LabEnvironment?) -> Bool {
		lab == nil
	}

	override init() {
		super.init()
		softStopFollowUp.isRunning = { [weak self] name in self?.isRunning?(name) ?? false }
		softStopFollowUp.askToForce = { [weak self] name in
			await self?.ask(.notShutDownYet(name)) == .forceStop
		}
		softStopFollowUp.force = { [weak self] name in
			Task { await self?.requestForceStop(name) }
		}
	}

	func openWindow(name: String, vz: VZVirtualMachine) {
		guard Self.opensWindows(lab: lab) else {
			MachmanLogger.log(.log, "test mode: no window for \(name) under the test suite")
			return
		}
		if let existing = windows[name] {
			// Re-surfacing must foreground the app, not just order the window forward.
			if managesActivationPolicy {
				NSApp.activate(ignoringOtherApps: true)
			}
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
		// Weak: the controller holds the window, and this closure lives inside its content.
		let capture = managesKeyCapture ? makeKeyCapture(for: window) : nil
		let content = VMView(
			vm: vz, onCreate: { [weak capture] view in capture?.attach(view) },
			captureStatus: capture?.status)
		window.contentView = NSHostingView(rootView: content)
		window.makeKeyAndOrderFront(nil)
		window.isReleasedWhenClosed = false
		window.delegate = self
		windows[name] = window
		if managesActivationPolicy, windows.count == 1 {
			NSApp.setActivationPolicy(.regular)
			NSApp.activate(ignoringOtherApps: true)
			window.makeKeyAndOrderFront(nil)   // re-front after the policy flip
		}
		onWindowChanged?()
	}

	// Close and forget without prompting (the VM went away on its own).
	func dropWindow(name: String) {
		let window = windows[name]
		forget(name)
		window?.close()
	}

	func window(for name: String) -> NSWindow? {
		windows[name]
	}

	// safeSave promotion: the vmhost's VM changes name mid-run — the window map and title
	// must follow, or close/stop lookups dead-end on the old key.
	func rekey(from oldName: String, to newName: String) {
		softStopFollowUp.rekey(from: oldName, to: newName)
		guard let window = windows.removeValue(forKey: oldName) else { return }
		windows[newName] = window
		window.title = newName
	}

	// Also ends a pending shutdown follow-up: the user let go of the window (or the VM
	// stopped), as the close prompt's Close Window says.
	private func forget(_ name: String) {
		softStopFollowUp.cancel(name)
		guard let window = windows[name] else { return }
		window.delegate = nil
		windows[name] = nil
		keyCaptures.removeValue(forKey: ObjectIdentifier(window))?.tearDown()
		if managesActivationPolicy, windows.isEmpty {
			NSApp.setActivationPolicy(.accessory)
		}
		onWindowChanged?()
	}

	// MARK: - System key capture

	private func makeKeyCapture(for window: NSWindow) -> KeyCaptureController {
		let controller = KeyCaptureController(
			window: window,
			mode: { [weak self, weak window] in
				guard let self, let window, let name = self.name(of: window) else { return .off }
				return self.captureMode?(name) ?? .off
			},
			setMode: { [weak self, weak window] mode in
				guard let self, let window, let name = self.name(of: window) else { return }
				self.setCaptureMode?(name, mode)
			})
		keyCaptures[ObjectIdentifier(window)] = controller
		return controller
	}

	private func name(of window: NSWindow) -> String? {
		windows.first { $0.value === window }?.key
	}

	private func keyCapture(_ notification: Notification) -> KeyCaptureController? {
		guard let window = notification.object as? NSWindow else { return nil }
		return keyCaptures[ObjectIdentifier(window)]
	}

	func windowDidBecomeKey(_ notification: Notification) {
		keyCapture(notification)?.windowDidBecomeKey()
	}

	func windowDidResignKey(_ notification: Notification) {
		keyCapture(notification)?.windowDidResignKey()
	}

	func windowDidEnterFullScreen(_ notification: Notification) {
		keyCapture(notification)?.windowDidEnterFullScreen()
	}

	func windowWillExitFullScreen(_ notification: Notification) {
		keyCapture(notification)?.windowWillExitFullScreen()
	}

	func windowDidExitFullScreen(_ notification: Notification) {
		keyCapture(notification)?.windowDidExitFullScreen()
	}

	func window(
		_ window: NSWindow,
		willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
	) -> NSApplication.PresentationOptions {
		keyCaptures[ObjectIdentifier(window)]?
			.fullScreenPresentationOptions(proposed: proposedOptions) ?? proposedOptions
	}

	func windowDidFailToEnterFullScreen(_ window: NSWindow) {
		keyCaptures[ObjectIdentifier(window)]?.windowDidFailToEnterFullScreen()
	}

	// The Keyboard menu acts on the VM window in front (a vmhost has just the one).
	private var activeKeyCapture: KeyCaptureController? {
		for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) {
			if let capture = keyCaptures[ObjectIdentifier(window)] {
				return capture
			}
		}
		return keyCaptures.count == 1 ? keyCaptures.values.first : nil
	}

	// VMHostApplication's key interceptor: a key event belongs to the VM window it is for.
	func interceptKey(_ event: NSEvent) -> Bool {
		guard let window = event.window ?? NSApp.keyWindow,
			let capture = keyCaptures[ObjectIdentifier(window)] else {
			return false
		}
		return capture.interceptKey(event)
	}

	@objc func selectCaptureMode(_ sender: NSMenuItem) {
		guard let raw = sender.representedObject as? String,
			let mode = SystemKeyCapture(rawValue: raw) else {
			return
		}
		activeKeyCapture?.setMode(mode, cause: "menu")
	}

	@objc func toggleCapture(_ sender: Any?) {
		activeKeyCapture?.toggle(cause: "menu")
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
		switch present(.closeWhileRunning(name)) {
		case .closeWindow:      // the VM keeps running headless
			forget(name)
			return true
		case .shutDown:         // the window stays to watch it happen
			Task { await requestShutDown(name) }
			return false
		case .forceStop:        // teardown closes the window
			Task { await requestForceStop(name) }
			return false
		case .keepWaiting, .quitAnyway, .cancel:
			return false
		}
	}

	// MARK: - Stop requests

	// Every Shut Down the vmhost offers: ask the guest, then follow up if it ignores the
	// request. A request the guest can't take right now (still starting, paused) says so at
	// once and offers a force stop.
	func requestShutDown(_ name: String) async {
		guard let stop = stopHandler else { return }
		do {
			try await stop(name, .soft)
			softStopFollowUp.schedule(name)
		} catch {
			if await ask(.shutDownRefused(name)) == .forceStop {
				await requestForceStop(name)
			}
		}
	}

	func requestForceStop(_ name: String) async {
		guard let stop = stopHandler else { return }
		do {
			try await stop(name, .force)
		} catch {
			_ = await ask(.forceStopFailed(name, reason: MachmanError.userMessage(for: error)))
		}
	}

	// MARK: - Prompts

	// Every vmhost prompt goes through here or ask (VMHostPrompts.swift). A test seam
	// answers in place of the modal alert.
	var answerPrompt: ((HostPrompt) -> HostChoice)?

	// A prompt AppKit asks for (the close button, a quit), from its own event dispatch.
	func present(_ prompt: HostPrompt) -> HostChoice {
		switch Self.route(hasSeam: answerPrompt != nil, lab: lab) {
		case .seam: return answerPrompt?(prompt) ?? .cancel
		case .lab: return labAnswer(prompt)
		case .alert: return runAlert(prompt)
		}
	}

	// A prompt a Task asks (a refused or failed stop, the follow-up): modal inside that
	// main-actor job it would stop this vmhost's server answering the daemon until it is
	// dismissed, so it starts from a run-loop callout (MainRunLoopCallout). A held lab answer
	// does the same.
	func ask(_ prompt: HostPrompt) async -> HostChoice {
		switch Self.route(hasSeam: answerPrompt != nil, lab: lab) {
		case .seam: return answerPrompt?(prompt) ?? .cancel
		case .lab: return await MainRunLoopCallout.run { self.labAnswer(prompt) }
		case .alert: return await MainRunLoopCallout.run { self.runAlert(prompt) }
		}
	}

	// Logged and answered from the answers file, never shown.
	private func labAnswer(_ prompt: HostPrompt) -> HostChoice {
		let index = LabAnswers.answerIfTesting(prompt.labPrompt, lab: lab)
		return index.map(prompt.choice(forButtonAt:)) ?? .cancel
	}

	// Brought to the front (PromptFront, the agent's rule too): a windowless host is lent a
	// Dock icon for the prompt, and bounces it if activation doesn't take — a log out drives
	// other apps too.
	private func runAlert(_ prompt: HostPrompt) -> HostChoice {
		let alert = NSAlert()
		alert.messageText = prompt.message
		alert.informativeText = prompt.info
		for button in prompt.buttons {
			alert.addButton(withTitle: button.title)
		}
		if let escape = prompt.escapeButton {
			alert.buttons[escape].keyEquivalent = "\u{1b}"
		}
		let steps = PromptFront.steps(
			ownsPolicy: managesActivationPolicy,
			hasDockIcon: NSApp.activationPolicy() == .regular)
		for step in steps {
			switch step {
			case .lendDockIcon: NSApp.setActivationPolicy(.regular)
			case .activate: NSApp.activate(ignoringOtherApps: true)
			case .requestAttention: NSApp.requestUserAttention(.criticalRequest)
			}
		}
		let response = alert.runModal()
		let lent = steps.contains(.lendDockIcon)
		if PromptFront.returnsToAccessory(lent: lent, windowsOpen: !windows.isEmpty) {
			NSApp.setActivationPolicy(.accessory)
		}
		return prompt.choice(forButtonAt:
			response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
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

	// One frame of the VM window via SCScreenshotManager: a one-shot capture (no stream
	// lifecycle churning the system's recording indicator), and onScreenWindowsOnly: false +
	// desktopIndependentWindow so windows parked on other Spaces still resolve. Always returns
	// an image (black fallback). Ceiling note: any ScreenCaptureKit path shows the system
	// capture indicator and needs Screen Recording permission — the plan to escape both is the
	// private-framebuffer PreviewSource (researched, deferred).
	func captureImage(name: String) async -> NSImage {
		let fallback = Self.blackImage(size: NSSize(width: 300, height: 200))
		guard Self.capturesPreviews(lab: lab) else {
			if reportedLabPreviews.insert(name).inserted {
				MachmanLogger.log(.log, "test mode: no preview for \(name) under the test suite")
			}
			return fallback
		}
		guard let window = windows[name] else { return fallback }
		// One capture at a time. This process is its own TCC responsible process now, so
		// preflight would answer honestly — but an undetermined grant still blocks the call on
		// the system's permission dialog, and every poll landing meanwhile would stack another
		// copy of it. Serialising stops the pile-up; we still never GATE on preflight —
		// attempting is what raises the prompt the user needs to see.
		guard !captureInFlight else { return fallback }
		captureInFlight = true
		defer { captureInFlight = false }

		let windowID = CGWindowID(window.windowNumber)
		let content: SCShareableContent
		do {
			content = try await SCShareableContent
				.excludingDesktopWindows(false, onScreenWindowsOnly: false)
		} catch {
			report(.noPermission)
			return fallback
		}
		guard let target = content.windows.first(where: { $0.windowID == windowID }) else {
			report(.windowNotFound(windowID))
			return fallback
		}
		let config = SCStreamConfiguration()
		config.width = Int(target.frame.width)
		config.height = Int(target.frame.height)
		let filter = SCContentFilter(desktopIndependentWindow: target)
		guard let cgImage = try? await SCScreenshotManager.captureImage(
			contentFilter: filter, configuration: config) else {
			report(.captureReturnedNothing)
			return fallback
		}
		return NSImage(
			cgImage: cgImage,
			size: NSSize(width: cgImage.width, height: cgImage.height))
	}

	// Logged as well as sent on the event bus, so the failure is visible even with no client
	// connected — exactly when someone is trying to work out why previews are blank.
	private func report(_ failure: CaptureFailure) {
		let key = "\(failure)"
		guard reportedFailures.insert(key).inserted else { return }
		// Preflight is a hint: it reflects the OS's cached answer for this process — the
		// responsible process itself, now that vmhosts launch standalone.
		let hint = CGPreflightScreenCaptureAccess() ? "" : " (this process preflights as denied)"
		MachmanLogger.log(.passiveWarning, "preview capture failed: \(key)\(hint)")
		onCaptureFailed?(failure)
	}
}

// Check marks for the Keyboard menu: the run's mode, and whether capture is on right now.
extension WindowPresenter: NSMenuItemValidation {
	func validateMenuItem(_ item: NSMenuItem) -> Bool {
		guard let capture = activeKeyCapture else { return false }
		switch item.action {
		case #selector(selectCaptureMode(_:)):
			let selected = item.representedObject as? String == capture.mode.rawValue
			item.state = selected ? .on : .off
		case #selector(toggleCapture(_:)):
			item.state = capture.isCapturing ? .on : .off
		default:
			break
		}
		return true
	}
}
