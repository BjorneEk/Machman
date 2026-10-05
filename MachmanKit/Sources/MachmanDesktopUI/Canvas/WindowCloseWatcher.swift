//
//  WindowCloseWatcher.swift
//  MachmanDesktopUI
//
//  Tells its view the moment the window holding it starts to close (NSWindow's willClose),
//  synchronously and before AppKit decides whether that was the app's last window — which a
//  SwiftUI onDisappear, coming after, can't. Takes no part in layout or hit testing.
//

import SwiftUI
import AppKit

struct WindowCloseWatcher: NSViewRepresentable {
	let willClose: (NSWindow) -> Void

	func makeNSView(context: Context) -> WatcherView {
		let view = WatcherView()
		view.willClose = willClose
		return view
	}

	func updateNSView(_ view: WatcherView, context: Context) {
		view.willClose = willClose
	}

	static func dismantleNSView(_ view: WatcherView, coordinator: ()) {
		view.stopWatching()
	}

	final class WatcherView: NSView {
		var willClose: ((NSWindow) -> Void)?
		private var observer: NSObjectProtocol?

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			stopWatching()
			guard let window else { return }
			observer = NotificationCenter.default.addObserver(
				forName: NSWindow.willCloseNotification, object: window, queue: nil
			) { [weak self] note in
				guard let window = note.object as? NSWindow else { return }
				MainActor.assumeIsolated { self?.willClose?(window) }
			}
		}

		func stopWatching() {
			if let observer { NotificationCenter.default.removeObserver(observer) }
			observer = nil
		}
	}
}
