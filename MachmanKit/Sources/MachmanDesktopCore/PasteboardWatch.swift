//
//  PasteboardWatch.swift
//  MachmanDesktopCore
//
//  What Paste can take right now (H25). Paste items in the menus read the general pasteboard
//  as they were built, and nothing observed it, so after a copy in Finder they stayed as
//  they were. macOS posts no pasteboard-change notification; its changeCount is the cheap
//  signal. The watch re-reads only when the count moved, on the triggers the app gives it
//  (activation, a window becoming key, a menu opening) and after Machman's own copies.
//  A read publishes its entities and files at once (Paste enables before the menu opens);
//  which tree sections the files fit is judged off the main thread, since a stat on a
//  network volume can stall (P11).
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
	// Each section's verdict on the files; nil while they aren't judged yet.
	private let fits: [TreeDragPreview.Section: Bool]?

	public static let sections: [TreeDragPreview.Section] = [
		.disks, .mounts, .kernel(.kernel), .kernel(.initramfs),
	]

	public init(
		entities: [EntityClipboard], fileURLs: [URL],
		isDirectory: (URL) -> Bool = TreeDropValidator.isDirectory
	) {
		self.init(
			entities: entities, fileURLs: fileURLs,
			fits: Self.fits(of: fileURLs, isDirectory: isDirectory))
	}

	private init(
		entities: [EntityClipboard], fileURLs: [URL], fits: [TreeDragPreview.Section: Bool]?
	) {
		self.entities = entities
		self.fileURLs = fileURLs
		self.fits = fits
	}

	// What a read takes from the pasteboard, its files not judged yet: the watch judges them
	// off the main thread.
	public static func unjudged(entities: [EntityClipboard], fileURLs: [URL]) -> Self {
		Self(entities: entities, fileURLs: fileURLs, fits: fileURLs.isEmpty ? [:] : nil)
	}

	public static let empty = PasteboardSnapshot(entities: [], fileURLs: [])

	// Which sections the files fit, each file statted once.
	static func fits(
		of fileURLs: [URL], isDirectory: (URL) -> Bool
	) -> [TreeDragPreview.Section: Bool] {
		guard !fileURLs.isEmpty else { return [:] }
		let known = TreeDropValidator.classified(fileURLs, isDirectory: isDirectory)
		var fits: [TreeDragPreview.Section: Bool] = [:]
		for section in sections {
			fits[section] = !TreeDropValidator.fitting(
				section: section, urls: fileURLs, isDirectory: known).isEmpty
		}
		return fits
	}

	var needsJudging: Bool { fits == nil }

	func judged(_ fits: [TreeDragPreview.Section: Bool]) -> Self {
		Self(entities: entities, fileURLs: fileURLs, fits: fits)
	}

	public var canPasteAnything: Bool { !entities.isEmpty || !fileURLs.isEmpty }

	// Copied entities decide when there are any (a section takes its own kind); otherwise
	// the file URLs that fit the section, by the drop rules.
	public func canPaste(into section: TreeDragPreview.Section) -> Bool {
		guard entities.isEmpty else {
			guard let kind = EntityClipboard.Kind(section: section) else { return false }
			return entities.contains { $0.kind == kind }
		}
		return fits?[section] ?? false
	}
}

@MainActor
public final class PasteboardWatch: ObservableObject {
	@Published public private(set) var snapshot: PasteboardSnapshot
	private let changeCount: @MainActor () -> Int
	private let read: @MainActor () -> PasteboardSnapshot
	private let isDirectory: @Sendable (URL) -> Bool
	private var lastCount: Int
	private var judging: Task<Void, Never>?
	private let observers: ObserverTokens

	// `read` may hand back an unjudged snapshot (PasteboardSnapshot.unjudged): the watch
	// judges its files with `isDirectory`, off the main thread.
	public init(
		center: NotificationCenter = .default, triggers: [Notification.Name],
		changeCount: @escaping @MainActor () -> Int,
		read: @escaping @MainActor () -> PasteboardSnapshot,
		isDirectory: @escaping @Sendable (URL) -> Bool = { TreeDropValidator.isDirectory($0) }
	) {
		self.changeCount = changeCount
		self.read = read
		self.isDirectory = isDirectory
		lastCount = changeCount()
		snapshot = .empty
		observers = ObserverTokens(center: center)
		for name in triggers {
			// Delivered on the main queue, so a trigger posted on the main thread (AppKit's
			// are) refreshes before it returns — a menu opening reads the new state.
			observers.add(center.addObserver(forName: name, object: nil, queue: .main) {
				[weak self] _ in
				MainActor.assumeIsolated { self?.refresh() }
			})
		}
		publish(read())
	}

	deinit {
		judging?.cancel()
	}

	// A watch that never reads the pasteboard: renders, hosted views and tests.
	public static func inert() -> PasteboardWatch {
		PasteboardWatch(triggers: [], changeCount: { 0 }, read: { .empty })
	}

	// Re-read only when the pasteboard changed since the last read.
	public func refresh() {
		let count = changeCount()
		guard count != lastCount else { return }
		lastCount = count
		publish(read())
	}

	// The read shows at once; its files' verdicts follow when judged, unless a newer read
	// came first.
	private func publish(_ read: PasteboardSnapshot) {
		judging?.cancel()
		judging = nil
		snapshot = read
		guard read.needsJudging else { return }
		let urls = read.fileURLs
		let isDirectory = self.isDirectory
		let count = lastCount
		judging = Task { [weak self] in
			let fits = await Task.detached(priority: .userInitiated) {
				PasteboardSnapshot.fits(of: urls, isDirectory: isDirectory)
			}.value
			guard !Task.isCancelled, let self, self.lastCount == count else { return }
			self.snapshot = read.judged(fits)
		}
	}
}
