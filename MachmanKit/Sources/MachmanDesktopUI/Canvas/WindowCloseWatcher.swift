//
//  WindowCloseWatcher.swift
//  MachmanDesktopUI
//
//  Tells its view the moment the window holding it starts to close (NSWindow's willClose),
//  synchronously and before AppKit decides whether that was the app's last window — which a
//  SwiftUI onDisappear, coming after, can't. A WindowWatcher configuration.
//

import SwiftUI
import AppKit

struct WindowCloseWatcher: View {
	let willClose: (NSWindow) -> Void

	var body: some View {
		WindowWatcher(handler: willClose) { view, window in
			window.observe([NSWindow.willCloseNotification]) { [weak view] note in
				guard let window = note.object as? NSWindow else { return }
				view?.handler(window)
			}
		}
	}
}
