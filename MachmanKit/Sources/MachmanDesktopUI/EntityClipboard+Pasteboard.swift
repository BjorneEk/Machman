//
//  EntityClipboard+Pasteboard.swift
//  MachmanDesktopUI
//
//  EntityClipboard on the general pasteboard: the JSON payload rides a custom pasteboard
//  type, with the plain path as a string for interop. Also the app's PasteboardWatch over
//  the general pasteboard, which every Paste item's enablement reads (H25) — under test mode
//  a watch that reads nothing.
//

import AppKit
import MachmanAPI
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
	// What the app's watch reads: the general pasteboard, or nothing under test mode (a Debug
	// build under a .test-<token> suite: scripts/test.sh, the lab), where views hosted in a test
	// run must never read the user's pasteboard. The .dev and Release suites always read it.
	enum GeneralSource: Equatable {
		case generalPasteboard, nothing
	}

	nonisolated static func generalSource(testMode: Bool) -> GeneralSource {
		testMode ? .nothing : .generalPasteboard
	}

	nonisolated static let generalSourceInThisProcess =
		generalSource(testMode: MachmanTestMode.isActive)

	// The general pasteboard, re-read when Machman becomes active, a window becomes key or a
	// menu opens (a context menu included) — each only when the pasteboard changed. No
	// timer: a change another app makes while Machman stays in front shows at the next menu.
	@MainActor
	public static let general = watch(generalSourceInThisProcess)

	@MainActor
	static func watch(_ source: GeneralSource) -> PasteboardWatch {
		switch source {
		case .nothing:
			return PasteboardWatch(triggers: [], changeCount: { 0 }, read: { .empty })
		case .generalPasteboard:
			return PasteboardWatch(
				triggers: [
					NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification,
					NSMenu.didBeginTrackingNotification,
				],
				changeCount: { NSPasteboard.general.changeCount },
				// Its files are judged off the main thread (P11).
				read: {
					.unjudged(
						entities: EntityClipboard.read(), fileURLs: AddFlows.pasteboardFileURLs())
				})
		}
	}
}
