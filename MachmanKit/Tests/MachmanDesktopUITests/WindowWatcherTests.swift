//
//  WindowWatcherTests.swift
//  MachmanDesktopUITests
//
//  Q35: the error alert's key watcher, a torn window's close watcher and a pane's click
//  watcher were one shape written three times. They are configurations of WindowWatcher
//  now; its subscription follows the view from window to window, which is checked here
//  once. Two never-ordered windows, under the offscreen host's gate.
//

import AppKit
import Testing
import MachmanTestSupport
@testable import MachmanDesktopUI

// L1: AppKit views in never-ordered windows.
@MainActor
struct WindowWatcherTests {
	private func window(_ title: String) -> HostWindow {
		let window = HostWindow(
			contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
			backing: .buffered, defer: true)
		window.isReleasedWhenClosed = false
		window.title = title
		return window
	}

	@Test("Q35: a window watcher re-subscribes when its view moves to another window")
	func aWatcherFollowsItsViewFromWindowToWindow() async throws {
		try await OffscreenHost.exclusively {
			var log: [String] = []
			let a = window("A")
			let b = window("B")
			let view = WindowWatcherView(handler: ()) { _, window in
				log.append("+\(window.title)")
				return { log.append("-\(window.title)") }
			}
			a.contentView?.addSubview(view)
			#expect(log == ["+A"])
			b.contentView?.addSubview(view)
			#expect(log == ["+A", "-A", "+B"])
			view.removeFromSuperview()
			#expect(log == ["+A", "-A", "+B", "-B"])
			// Dismantled by SwiftUI while still in a window: unsubscribed, and only once.
			a.contentView?.addSubview(view)
			view.stopWatching()
			view.removeFromSuperview()
			#expect(log == ["+A", "-A", "+B", "-B", "+A", "-A"])
			// Taking no part in hit testing.
			#expect(view.hitTest(.zero) == nil)
			a.close()
			b.close()
		}
	}
}
