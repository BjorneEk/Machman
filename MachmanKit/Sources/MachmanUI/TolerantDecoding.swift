//
//  TolerantDecoding.swift
//  MachmanUI
//
//  Decoding for the desktop's settings files (terminal profiles, canvas layouts): one bad
//  value costs that value, never the file. A field another build wrote differently (an enum
//  case this build doesn't know, a missing or retyped key) falls back to its default, and a
//  bad element of a list or dictionary is dropped. Only a file that isn't the expected JSON
//  at all fails to load, and PersistedJSONFile sets that one aside instead of overwriting it.
//

import Foundation

extension KeyedDecodingContainer {
	// The value, or nil when it is absent, null or undecodable.
	public func decodeTolerant<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
		(try? decodeIfPresent(type, forKey: key)) ?? nil
	}

	// The elements that decode, in order; an absent or mistyped list is empty.
	public func decodeTolerantArray<T: Decodable>(of type: T.Type, forKey key: Key) -> [T] {
		(decodeTolerant([Tolerant<T>].self, forKey: key) ?? []).compactMap(\.value)
	}

	// The entries whose values decode; an absent or mistyped dictionary is empty.
	public func decodeTolerantDictionary<T: Decodable>(
		of type: T.Type, forKey key: Key
	) -> [String: T] {
		(decodeTolerant([String: Tolerant<T>].self, forKey: key) ?? [:]).compactMapValues(\.value)
	}
}

// One element of a tolerant collection: nil when it doesn't decode.
public struct Tolerant<T: Decodable>: Decodable {
	public let value: T?

	public init(from decoder: Decoder) throws {
		value = try? T(from: decoder)
	}
}
