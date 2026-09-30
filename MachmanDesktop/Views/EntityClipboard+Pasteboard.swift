//
//  EntityClipboard+Pasteboard.swift
//  MachmanDesktop
//
//  EntityClipboard on the general pasteboard: the JSON payload rides a custom pasteboard
//  type, with the plain path as a string for interop.
//

import AppKit

extension EntityClipboard {
	static let pasteboardType = NSPasteboard.PasteboardType(
		"com.gustaffranzen.machman.entity")

	// MARK: - Pasteboard (the payload is a LIST — multi-selections copy together)

	static func write(_ items: [EntityClipboard]) {
		guard !items.isEmpty else { return }
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		if let data = try? JSONEncoder().encode(items) {
			pasteboard.setData(data, forType: pasteboardType)
		}
		pasteboard.setString(
			items.map(\.path).joined(separator: "\n"), forType: .string)
	}

	static func write(_ item: EntityClipboard) {
		write([item])
	}

	static func read() -> [EntityClipboard] {
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
