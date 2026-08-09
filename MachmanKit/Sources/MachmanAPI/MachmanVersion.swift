//
//  MachmanVersion.swift
//  MachmanAPI
//
//  Dotted-version comparison for the build-skew prompts. Policy: any commit that changes wire
//  shapes, the config format, or daemon behavior an old/new mix can't tolerate bumps the patch
//  version AND the desktop's compatibility floor. Suffixes ("1.0.1-vmhost") are ignored;
//  unparseable strings compare as OLDEST, so a prehistoric "dev"-versioned daemon triggers the
//  prompt instead of slipping through.
//

import Foundation

public enum MachmanVersion {
	// The leading dotted-numeric components, or nil when there are none.
	static func components(_ string: String) -> [Int]? {
		let prefix = string.prefix { $0.isNumber || $0 == "." }
		let parts = prefix.split(separator: ".", omittingEmptySubsequences: false)
		let numbers = parts.compactMap { Int($0) }
		guard !numbers.isEmpty, numbers.count == parts.count else { return nil }
		return numbers
	}

	public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
		let l = components(lhs)
		let r = components(rhs)
		switch (l, r) {
		case (nil, nil): return .orderedSame
		case (nil, _): return .orderedAscending      // unparseable = oldest
		case (_, nil): return .orderedDescending
		case (let l?, let r?):
			let count = max(l.count, r.count)
			for i in 0..<count {
				let a = i < l.count ? l[i] : 0
				let b = i < r.count ? r[i] : 0
				if a != b { return a < b ? .orderedAscending : .orderedDescending }
			}
			return .orderedSame
		}
	}

	public static func isOlder(_ lhs: String, than rhs: String) -> Bool {
		compare(lhs, rhs) == .orderedAscending
	}
}
