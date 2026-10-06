//
//  VMPickerKeys.swift
//  MachmanDesktopCore
//
//  The VM picker's keyboard (H49, C10). The search field narrowed the list but couldn't
//  pick: Return opens the highlighted row, else the first match; ↑/↓ move the highlight and
//  stop at the ends; typing puts it on the first match, clearing the field takes it away.
//

import Foundation

public struct VMPickerKeys: Equatable {
	public private(set) var highlighted: String?

	public init(highlighted: String? = nil) {
		self.highlighted = highlighted
	}

	// The list a new query left: what Return would open is highlighted while there is a query.
	public mutating func queryChanged(_ query: String, matches: [String]) {
		highlighted = query.isEmpty ? nil : matches.first
	}

	// ↓ (+1) or ↑ (-1): from no highlight, the first or the last row.
	public mutating func move(_ delta: Int, in matches: [String]) {
		guard !matches.isEmpty else {
			highlighted = nil
			return
		}
		guard let current = highlighted.flatMap(matches.firstIndex(of:)) else {
			highlighted = delta > 0 ? matches.first : matches.last
			return
		}
		highlighted = matches[min(max(current + delta, 0), matches.count - 1)]
	}

	// What Return opens: the highlighted row, else the first match.
	public func pick(in matches: [String]) -> String? {
		highlighted.flatMap { matches.contains($0) ? $0 : nil } ?? matches.first
	}
}
