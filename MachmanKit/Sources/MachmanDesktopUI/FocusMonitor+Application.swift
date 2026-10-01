//
//  FocusMonitor+Application.swift
//  MachmanDesktopUI
//
//  The app's own focus: Machman is the active app and one of its windows — the main window,
//  a torn-off tab, Settings, a sheet — is key (T18). Clicking from the main window into a
//  torn-off one is no longer "unfocused".
//

import AppKit
import MachmanDesktopCore

extension FocusMonitor {
	// NSApplication.shared, not NSApp: this runs from the App's init.
	public static func application(
		onChange: @escaping @MainActor (Bool) -> Void
	) -> FocusMonitor {
		FocusMonitor(
			names: [
				NSApplication.didBecomeActiveNotification,
				NSApplication.didResignActiveNotification,
				NSWindow.didBecomeKeyNotification,
				NSWindow.didResignKeyNotification,
			],
			probe: { NSApplication.shared.isActive && NSApplication.shared.keyWindow != nil },
			onChange: onChange)
	}
}
