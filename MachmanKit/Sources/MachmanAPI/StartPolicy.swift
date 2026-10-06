//
//  StartPolicy.swift
//  MachmanAPI
//
//  How a VM prefers to be started. Three orthogonal switches; defaults-on-decode so old
//  payloads and old configs read as today's behavior (windowed, real disks, manual start).
//  Persisted directly inside VMConfig AND carried on the wire in VMInfo — it has no Date
//  fields, so it is safe under both the persistence and wire coders.
//

import Foundation

public struct StartPolicy: Codable, Sendable, Equatable {
	public var windowed: Bool
	public var safe: Bool
	public var autostart: Bool

	public init(windowed: Bool = true, safe: Bool = false, autostart: Bool = false) {
		self.windowed = windowed
		self.safe = safe
		self.autostart = autostart
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.windowed = try c.decodeIfPresent(Bool.self, forKey: .windowed) ?? true
		self.safe = try c.decodeIfPresent(Bool.self, forKey: .safe) ?? false
		self.autostart = try c.decodeIfPresent(Bool.self, forKey: .autostart) ?? false
	}
}

// Safe mode and Start at login rule each other out (H52): an autostarted safe run has nowhere
// to put its discardable state in v1. The daemon refuses the pair with this sentence, and a
// client dims each switch while the other is on, saying the same. A policy with both on (a
// hand-edited config) refuses neither, so either can still be switched off.
extension StartPolicy {
	public static let safeAutostartRefusal = "A safe run can\u{2019}t start automatically"

	// Why Safe mode can't be switched on now, or nil.
	public var safeRefusal: String? {
		autostart && !safe ? Self.safeAutostartRefusal : nil
	}

	// Why Start at login can't be switched on now, or nil.
	public var autostartRefusal: String? {
		safe && !autostart ? Self.safeAutostartRefusal : nil
	}
}
