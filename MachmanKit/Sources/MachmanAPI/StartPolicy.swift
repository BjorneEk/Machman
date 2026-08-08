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
