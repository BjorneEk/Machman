//
//  FocusAndTopmostTracker.swift
//  MachmanDesktop
//
//  Reports whether this app's window is both key AND frontmost, so the preview loop only runs
//  while the VM's pane is actually visible to the user. Formerly nested in MainVMView; lifted out
//  when that view became the VM tab container so the tracker survives across tab switches.
//

import SwiftUI
import AppKit

struct FocusAndTopmostTracker: NSViewRepresentable {
	let onChange: (Bool) -> Void

	class Coordinator: NSObject {
		weak var window: NSWindow?
		var onChange: (Bool) -> Void
		var lastState: Bool = false
		var checkTimer: Timer?

		init(onChange: @escaping (Bool) -> Void) {
			self.onChange = onChange
		}

		func attach(to window: NSWindow) {
			self.window = window

			NotificationCenter.default.addObserver(self,
				selector: #selector(updateFocusState),
				name: NSWindow.didBecomeKeyNotification,
				object: window)

			NotificationCenter.default.addObserver(self,
				selector: #selector(updateFocusState),
				name: NSWindow.didResignKeyNotification,
				object: window)

			startChecking()
		}

		@objc func updateFocusState() {
			checkState()
		}

		func startChecking() {
			checkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
				self.checkState()
			}
		}

		func checkState() {
			guard let window = window else { return }
			let isKey = window.isKeyWindow
			let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
				== NSRunningApplication.current.processIdentifier

			let currentState = isKey && isFrontmost
			if currentState != lastState {
				lastState = currentState
				onChange(currentState)
			}
		}

		deinit {
			checkTimer?.invalidate()
		}
	}

	func makeCoordinator() -> Coordinator {
		return Coordinator(onChange: onChange)
	}

	func makeNSView(context: Context) -> NSView {
		let view = NSView()
		DispatchQueue.main.async {
			if let window = view.window ?? NSApp.windows.first {
				context.coordinator.attach(to: window)
				context.coordinator.checkState()
			}
		}
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {}
}
