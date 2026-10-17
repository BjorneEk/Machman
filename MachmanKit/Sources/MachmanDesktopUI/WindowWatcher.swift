//
//  WindowWatcher.swift
//  MachmanDesktopUI
//
//  The one shape of a view that watches the window holding it (Q35): a view that takes no
//  part in layout or hit testing, subscribes for its window when it moves into one, undoes
//  that when it moves to another or out, and again when SwiftUI dismantles it. A watcher is
//  a configuration over it — what to subscribe to, and the handler the subscription calls
//  (the error alert's key watcher, a torn window's close watcher, a pane's click watcher).
//  An update replaces the handler without re-subscribing: subscriptions call through
//  `view.handler`.
//

import SwiftUI
import AppKit

struct WindowWatcher<Handler>: NSViewRepresentable {
	let handler: Handler
	// Subscribes `view` for `window` and returns what undoes it.
	let subscribe: @MainActor (WindowWatcherView<Handler>, NSWindow) -> () -> Void

	func makeNSView(context: Context) -> WindowWatcherView<Handler> {
		WindowWatcherView(handler: handler, subscribe: subscribe)
	}

	func updateNSView(_ view: WindowWatcherView<Handler>, context: Context) {
		view.handler = handler
	}

	static func dismantleNSView(_ view: WindowWatcherView<Handler>, coordinator: ()) {
		view.stopWatching()
	}
}

final class WindowWatcherView<Handler>: NSView {
	var handler: Handler
	private let subscribe: @MainActor (WindowWatcherView<Handler>, NSWindow) -> () -> Void
	private var unsubscribe: (() -> Void)?

	init(
		handler: Handler,
		subscribe: @escaping @MainActor (WindowWatcherView<Handler>, NSWindow) -> () -> Void
	) {
		self.handler = handler
		self.subscribe = subscribe
		super.init(frame: .zero)
	}

	// Made in code only: it has no handler to decode.
	required init?(coder: NSCoder) {
		return nil
	}

	override func hitTest(_ point: NSPoint) -> NSView? { nil }

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		stopWatching()
		guard let window else { return }
		unsubscribe = subscribe(self, window)
	}

	func stopWatching() {
		unsubscribe?()
		unsubscribe = nil
	}
}

extension NSWindow {
	// Notifications this window posts — all on the main thread, so `body` runs right there,
	// inside the post (a close watcher must act before AppKit's last-window check). Returns
	// what removes the observers.
	func observe(
		_ names: [Notification.Name], _ body: @escaping @MainActor (Notification) -> Void
	) -> () -> Void {
		let center = NotificationCenter.default
		let tokens = names.map { name in
			center.addObserver(forName: name, object: self, queue: nil) { note in
				MainActor.assumeIsolated { body(note) }
			}
		}
		return { tokens.forEach(center.removeObserver) }
	}
}
