//
//  PaneClickWatcher.swift
//  MachmanDesktopUI
//
//  Reports a mouse-down anywhere in a canvas pane's content (T23). That content is mostly
//  AppKit — a terminal, the display preview — which takes the click before a SwiftUI gesture
//  could see it, so a local event monitor watches for it instead. The watcher never consumes
//  the event; it watches only while it is in a window (a WindowWatcher configuration).
//

import SwiftUI
import AppKit

struct PaneClickWatcher: View {
	let onMouseDown: () -> Void

	var body: some View {
		WindowWatcher(handler: onMouseDown) { view, _ in
			let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
				[weak view] event in
				// Local monitors run on the main thread, inside AppKit's event dispatch.
				MainActor.assumeIsolated { view.map { Self.noticed(event, in: $0) } }
				return event
			}
			return { monitor.map(NSEvent.removeMonitor) }
		}
	}

	// After the click has gone where it was going: the model change must not land inside
	// AppKit's event dispatch.
	private static func noticed(_ event: NSEvent, in view: WindowWatcherView<() -> Void>) {
		guard let window = view.window, event.window === window,
			!view.isHiddenOrHasHiddenAncestor,
			view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return }
		DispatchQueue.main.async { [weak view] in view?.handler() }
	}
}
