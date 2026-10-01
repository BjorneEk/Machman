//
//  TextEditingMonitor.swift
//  MachmanDesktop
//
//  Whether the key window's first responder takes text input — a text field's field editor,
//  a text view, a terminal (SwiftTerm's TerminalView is an NSTextInputClient). File ▸ Delete
//  VM… (⌘⌫) is off while it does, and a disabled menu item doesn't consume its key
//  equivalent, so ⌘⌫ keeps deleting to the start of the line. Observes only: it never moves
//  focus.
//

import AppKit
import Combine

@MainActor
final class TextEditingMonitor: ObservableObject {
	@Published private(set) var isEditingText = false
	private var keyWindowObserver: NSObjectProtocol?
	private var responderObservation: NSKeyValueObservation?

	init() {
		keyWindowObserver = NotificationCenter.default.addObserver(
			forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
		) { [weak self] note in
			guard let window = note.object as? NSWindow else { return }
			MainActor.assumeIsolated { self?.watch(window) }
		}
		if let key = NSApp?.keyWindow { watch(key) }
	}

	deinit {
		if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
	}

	// firstResponder is KVO-compliant (NSWindow.h). Published a turn later: a responder
	// change can land in the middle of a view update.
	private func watch(_ window: NSWindow) {
		responderObservation = window.observe(\.firstResponder, options: [.initial, .new]) {
			[weak self] window, _ in
			let editing = window.firstResponder is NSTextInputClient
			DispatchQueue.main.async {
				guard let self, self.isEditingText != editing else { return }
				self.isEditingText = editing
			}
		}
	}
}
