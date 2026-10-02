//
//  EntityClipboard+Pasteboard.swift
//  MachmanDesktopUI
//
//  EntityClipboard on the general pasteboard: the JSON payload rides a custom pasteboard
//  type, with the plain path as a string for interop. Also the app's PasteboardWatch over
//  the general pasteboard, which every Paste item's enablement reads (H25).
//

import AppKit
import MachmanDesktopCore

extension EntityClipboard {
	static let pasteboardType = NSPasteboard.PasteboardType(
		"com.gustaffranzen.machman.entity")

	// MARK: - Pasteboard (the payload is a LIST — multi-selections copy together)

	@MainActor
	public static func write(_ items: [EntityClipboard]) {
		guard !items.isEmpty else { return }
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		if let data = try? JSONEncoder().encode(items) {
			pasteboard.setData(data, forType: pasteboardType)
		}
		pasteboard.setString(
			items.map(\.path).joined(separator: "\n"), forType: .string)
		PasteboardWatch.general.refresh()   // Paste enables at once
	}

	@MainActor
	public static func write(_ item: EntityClipboard) {
		write([item])
	}

	public static func read() -> [EntityClipboard] {
		guard let data = NSPasteboard.general.data(forType: pasteboardType) else {
			return []
		}
		if let items = try? JSONDecoder().decode([EntityClipboard].self, from: data) {
			return items
		}
		// A single-item payload from an older build.
		if let item = try? JSONDecoder().decode(EntityClipboard.self, from: data) {
			return [item]
		}
		return []
	}
}

extension PasteboardWatch {
	// The general pasteboard, re-read when Machman becomes active, a window becomes key or a
	// menu opens (a context menu included) — each only when the pasteboard changed. No
	// timer: a change another app makes while Machman stays in front shows at the next menu.
	@MainActor
	public static let general = PasteboardWatch(
		triggers: [
			NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification,
			NSMenu.didBeginTrackingNotification,
		],
		changeCount: { NSPasteboard.general.changeCount },
		read: {
			PasteboardSnapshot(
				entities: EntityClipboard.read(), fileURLs: AddFlows.pasteboardFileURLs())
		})
}
