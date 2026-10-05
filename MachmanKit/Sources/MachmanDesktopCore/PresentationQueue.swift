//
//  PresentationQueue.swift
//  MachmanDesktopCore
//
//  One-at-a-time presentation (an alert, a confirmation dialog) over a FIFO: an item that
//  arrives while another is showing waits its turn instead of replacing it.
//

import Foundation

public struct PresentationQueue<Item> {
	// What is showing now; nil between items and when nothing is queued.
	public private(set) var current: Item?
	public private(set) var waiting: [Item] = []

	public init() {}

	// Shows the item at once when nothing is showing or waiting; otherwise it waits behind
	// the rest. An item `duplicate` matches against one showing or waiting is dropped.
	public mutating func enqueue(
		_ item: Item, duplicate: (Item, Item) -> Bool = { _, _ in false }
	) {
		if let current, duplicate(current, item) { return }
		if waiting.contains(where: { duplicate($0, item) }) { return }
		if current == nil, waiting.isEmpty {
			current = item
		} else {
			waiting.append(item)
		}
	}

	// The shown item was dismissed. True when another waits, so the caller presents it
	// (through advance()) once the dismissal has finished animating.
	public mutating func dismiss() -> Bool {
		guard current != nil else { return false }
		current = nil
		return !waiting.isEmpty
	}

	// Drops the waiting items that match; the one showing stays (dismiss it to go on).
	public mutating func removeWaiting(where match: (Item) -> Bool) {
		waiting.removeAll(where: match)
	}

	public mutating func advance() {
		guard current == nil, !waiting.isEmpty else { return }
		current = waiting.removeFirst()
	}
}
