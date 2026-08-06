//
//  MachmanError.swift
//  MachmanAPI
//
//  The error shape that crosses the API. Codes are frozen wire values; message is
//  human-readable detail.
//

import Foundation

public struct MachmanError: Error, Codable, Sendable, Equatable {
	public enum Code: String, Codable, Sendable {
		case notFound
		case alreadyExists
		case invalidState        // e.g. start while installing, delete while running
		case invalidArgument
		case ioFailure
		case virtualizationFailure
		case installFailure
		case internalError

		public init(from decoder: Decoder) throws {
			let raw = try decoder.singleValueContainer().decode(String.self)
			self = Code(rawValue: raw) ?? .internalError
		}
	}

	public var code: Code
	public var message: String

	public init(code: Code, message: String) {
		self.code = code
		self.message = message
	}

	public static func notFound(_ name: String) -> MachmanError {
		MachmanError(code: .notFound, message: "no VM named '\(name)'")
	}
}

extension MachmanError: LocalizedError {
	public var errorDescription: String? { message }
}
