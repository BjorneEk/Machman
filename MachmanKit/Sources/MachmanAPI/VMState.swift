//
//  VMState.swift
//  MachmanAPI
//
//  Runtime state of a VM as reported by the engine. Part of the wire contract: raw values are
//  frozen; unrecognized values decode to .unknown so old clients survive new daemon states.
//

import Foundation

public enum VMState: String, Codable, Sendable, Equatable, CaseIterable {
	case stopped
	case starting
	case running
	case stopping
	case paused
	case error
	case unknown

	public init(from decoder: Decoder) throws {
		let raw = try decoder.singleValueContainer().decode(String.self)
		self = VMState(rawValue: raw) ?? .unknown
	}

	public var isRunning: Bool {
		switch self {
		case .running, .starting, .stopping, .paused:
			return true
		case .stopped, .error, .unknown:
			return false
		}
	}
}

public enum LogLevel: String, Codable, Sendable, Equatable {
	case message
	case warning
	case error

	public init(from decoder: Decoder) throws {
		let raw = try decoder.singleValueContainer().decode(String.self)
		self = LogLevel(rawValue: raw) ?? .message
	}
}
