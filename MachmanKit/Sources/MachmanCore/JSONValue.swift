//
//  JSONValue.swift
//  MachmanCore
//
//  A JSON value kept as read, for the parts of a config this build can't interpret (D26: a
//  boot mode a newer Machman wrote). Decoding then encoding one writes the same value back —
//  every key, string and number — so a save never rewrites what an older build doesn't know.
//  Numbers keep their kind: integers decode as Int64 (UInt64 past it), anything else as
//  Double, and JSONEncoder spells each the way the writer's JSONEncoder did.
//

import Foundation

indirect enum JSONValue: Codable, Equatable {
	case null
	case bool(Bool)
	case int(Int64)
	case uint(UInt64)
	case double(Double)
	case string(String)
	case array([JSONValue])
	case object([String: JSONValue])

	private struct Key: CodingKey {
		let stringValue: String
		var intValue: Int? { nil }

		init(stringValue: String) {
			self.stringValue = stringValue
		}

		init?(intValue: Int) {
			nil
		}
	}

	init(from decoder: any Decoder) throws {
		if let object = try? decoder.container(keyedBy: Key.self) {
			var members: [String: JSONValue] = [:]
			for key in object.allKeys {
				members[key.stringValue] = try object.decode(JSONValue.self, forKey: key)
			}
			self = .object(members)
			return
		}
		if var array = try? decoder.unkeyedContainer() {
			var elements: [JSONValue] = []
			while !array.isAtEnd {
				elements.append(try array.decode(JSONValue.self))
			}
			self = .array(elements)
			return
		}
		let value = try decoder.singleValueContainer()
		if value.decodeNil() {
			self = .null
		} else if let bool = try? value.decode(Bool.self) {
			self = .bool(bool)
		} else if let int = try? value.decode(Int64.self) {
			self = .int(int)
		} else if let uint = try? value.decode(UInt64.self) {
			self = .uint(uint)
		} else if let double = try? value.decode(Double.self) {
			self = .double(double)
		} else {
			self = .string(try value.decode(String.self))
		}
	}

	func encode(to encoder: any Encoder) throws {
		switch self {
		case .object(let members):
			var object = encoder.container(keyedBy: Key.self)
			for (key, member) in members {
				try object.encode(member, forKey: Key(stringValue: key))
			}
		case .array(let elements):
			var array = encoder.unkeyedContainer()
			for element in elements {
				try array.encode(element)
			}
		case .null:
			var value = encoder.singleValueContainer()
			try value.encodeNil()
		case .bool(let bool):
			var value = encoder.singleValueContainer()
			try value.encode(bool)
		case .int(let int):
			var value = encoder.singleValueContainer()
			try value.encode(int)
		case .uint(let uint):
			var value = encoder.singleValueContainer()
			try value.encode(uint)
		case .double(let double):
			var value = encoder.singleValueContainer()
			try value.encode(double)
		case .string(let string):
			var value = encoder.singleValueContainer()
			try value.encode(string)
		}
	}
}
