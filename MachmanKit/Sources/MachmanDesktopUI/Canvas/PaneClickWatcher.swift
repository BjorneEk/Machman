//
//  PaneClickWatcher.swift
//  MachmanDesktopUI
//
//  Reports a mouse-down anywhere in a canvas pane's content (T23). That content is mostly
//  AppKit — a terminal, the display preview — which takes the click before a SwiftUI gesture
//  could see it, so a local event monitor watches for it instead. The watcher never consumes
//  the event and takes no part in hit testing; it watches only while it is in a window.
//

import SwiftUI
import AppKit

struct PaneClickWatcher: NSViewRepresentable {
	let onMouseDown: () -> Void

	func makeNSView(context: Context) -> WatcherView {
		let view = WatcherView()
		view.onMouseDown = onMouseDown
		return view
	}

	func updateNSView(_ view: WatcherView, context: Context) {
		view.onMouseDown = onMouseDown
	}

	static func dismantleNSView(_ view: WatcherView, coordinator: ()) {
		view.stopWatching()
	}

	final class WatcherView: NSView {
		var onMouseDown: (() -> Void)?
		private var monitor: Any?

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			stopWatching()
			guard window != nil else { return }
			monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
				[weak self] event in
				self?.noticed(event)
				return event
			}
		}

		func stopWatching() {
			if let monitor { NSEvent.removeMonitor(monitor) }
			monitor = nil
		}

		// After the click has gone where it was going: the model change must not land
		// inside AppKit's event dispatch.
		private func noticed(_ event: NSEvent) {
			guard let window, event.window === window, !isHiddenOrHasHiddenAncestor,
				bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
			DispatchQueue.main.async { [weak self] in self?.onMouseDown?() }
		}
	}
}
