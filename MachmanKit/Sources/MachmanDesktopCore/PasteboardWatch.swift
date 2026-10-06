//
//  PasteboardWatch.swift
//  MachmanDesktopCore
//
//  What Paste can take right now (H25). Paste items in the menus read the general pasteboard
//  as they were built, and nothing observed it, so after a copy in Finder they stayed as
//  they were. macOS posts no pasteboard-change notification; its changeCount is the cheap
//  signal. The watch re-reads only when the count moved, on the triggers the app gives it
//  (activation, a window becoming key, a menu opening) and after Machman's own copies.
//  No AppKit here: the pasteboard comes in as closures (the app's watch is in
//  MachmanDesktopUI's EntityClipboard+Pasteboard.swift). The paste actions themselves still
//  read fresh — a user-originated paste.
//

import Foundation
import MachmanAPI

// One read of the pasteboard: Machman's copied entities and plain file URLs, with each
// tree section's verdict computed once (the drop rules; each file statted once per read).
public struct PasteboardSnapshot {
	public let entities: [EntityClipboard]
	public let fileURLs: [URL]
	private let fits: [TreeDragPreview.Section: Bool]

	public static let sections: [TreeDragPreview.Section] = [
		.disks, .mounts, .kernel(.kernel), .kernel(.initramfs),
	]

	public init(
		entities: [EntityClipboard], fileURLs: [URL],
		isDirectory: (URL) -> Bool = TreeDropValidator.isDirectory
	) {
		self.entities = entities
		self.fileURLs = fileURLs
		var fits: [TreeDragPreview.Section: Bool] = [:]
		if !fileURLs.isEmpty {
			let known = TreeDropValidator.classified(fileURLs, isDirectory: isDirectory)
			for section in Self.sections {
				fits[section] = !TreeDropValidator.fitting(
					section: section, urls: fileURLs, isDirectory: known).isEmpty
			}
		}
		self.fits = fits
	}

	public static let empty = PasteboardSnapshot(entities: [], fileURLs: [])

	public var canPasteAnything: Bool { !entities.isEmpty || !fileURLs.isEmpty }

	// Copied entities decide when there are any (a section takes its own kind); otherwise
	// the file URLs that fit the section, by the drop rules.
	public func canPaste(into section: TreeDragPreview.Section) -> Bool {
		guard entities.isEmpty else {
			guard let kind = EntityClipboard.Kind(section: section) else { return false }
			return entities.contains { $0.kind == kind }
		}
		return fits[section] ?? false
	}
}

@MainActor
public final class PasteboardWatch: ObservableObject {
	@Published public private(set) var snapshot: PasteboardSnapshot
	private let changeCount: @MainActor () -> Int
	private let read: @MainActor () -> PasteboardSnapshot
	private var lastCount: Int
	private let observers: ObserverTokens

	public init(
		center: NotificationCenter = .default, triggers: [Notification.Name],
		changeCount: @escaping @MainActor () -> Int,
		read: @escaping @MainActor () -> PasteboardSnapshot
	) {
		self.changeCount = changeCount
		self.read = read
		lastCount = changeCount()
		snapshot = read()
		observers = ObserverTokens(center: center)
		for name in triggers {
			// Delivered on the main queue, so a trigger posted on the main thread (AppKit's
			// are) refreshes before it returns — a menu opening reads the new state.
			observers.add(center.addObserver(forName: name, object: nil, queue: .main) {
				[weak self] _ in
				MainActor.assumeIsolated { self?.refresh() }
			})
		}
	}

	// Re-read only when the pasteboard changed since the last read.
	public func refresh() {
		let count = changeCount()
		guard count != lastCount else { return }
		lastCount = count
		snapshot = read()
	}
}
