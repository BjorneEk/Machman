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
		case macConflict         // start refused: a running VM already uses this MAC (force overrides)
		case invalidArgument
		case ioFailure
		case virtualizationFailure
		case installFailure
		case internalError
		// A bounded call got no reply before its client-side deadline (1.0.9+, additive:
		// the call fails, the connection and the serving process are left alone).
		case timeout
		// The user canceled what the call was doing — a Stop or ✕ while a safe start prepared
		// (additive, review F11): a never-mind, not a failure. Older clients read internalError.
		case cancelled

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
		MachmanError(code: .notFound, message: "No VM named \u{201C}\(name)\u{201D}")
	}
}

extension MachmanError: LocalizedError {
	public var errorDescription: String? { message }
}

// "\(error)" reads the message too (E28: failed operation cards showed the struct dump);
// logs that want the code use String(reflecting:). Codable stays code + message.
extension MachmanError: CustomStringConvertible, CustomDebugStringConvertible {
	public var description: String { message }
	public var debugDescription: String { "MachmanError(\(code.rawValue)): \(message)" }
}

extension MachmanError {
	// The one rule for showing any error to a person (E28, wording rule 6): its own
	// sentence, never a struct dump or an NSError's "Error Domain=… Code=…". In order: a
	// MachmanError's message; "Canceled" for a cancelled task; a LocalizedError's text; a
	// Swift error type with no localized text by its own description (NSError bridging names
	// its domain after the type, and would answer boilerplate); anything else by its
	// localized description, plus its failure reason when the error carries that apart from
	// the description (Virtualization's "Installation failed." says why only there).
	public static func userMessage(for error: Error) -> String {
		if let error = error as? MachmanError { return error.message }
		if error is CancellationError { return "Canceled" }
		if let text = (error as? LocalizedError)?.errorDescription { return text }
		let ns = error as NSError
		if ns.domain == String(reflecting: type(of: error)) { return String(describing: error) }
		let description = ns.localizedDescription
		guard ns.userInfo[NSLocalizedDescriptionKey] is String,
			let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String,
			!reason.isEmpty, !description.contains(reason)
		else { return description }
		return "\(description) \(reason)"
	}
}
