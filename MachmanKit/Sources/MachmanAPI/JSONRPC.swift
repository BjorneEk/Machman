//
//  JSONRPC.swift
//  MachmanAPI
//
//  JSON-RPC 2.0 envelope for the Machman socket protocol. One JSON object per line
//  (newline-delimited; MachmanWire output never contains raw newlines). Requests carry an id;
//  server-initiated event notifications carry none. Void results encode as {}.
//
//  Error codes: standard JSON-RPC (-32700 parse, -32600 invalid request, -32601 method not
//  found, -32602 invalid params, -32603 internal) plus -32000 for application errors, whose
//  `data.machmanCode` holds the MachmanError code string.
//

import Foundation

public enum JSONRPC {
	public static let version = "2.0"

	public static let parseError = -32700
	public static let invalidRequest = -32600
	public static let methodNotFound = -32601
	public static let invalidParams = -32602
	public static let internalError = -32603
	public static let applicationError = -32000
}

// Request/response id: number or string, per the JSON-RPC spec.
public enum RPCID: Codable, Equatable, Sendable, Hashable {
	case number(Int)
	case string(String)

	public init(from decoder: Decoder) throws {
		let c = try decoder.singleValueContainer()
		if let n = try? c.decode(Int.self) {
			self = .number(n)
		} else {
			self = .string(try c.decode(String.self))
		}
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.singleValueContainer()
		switch self {
		case .number(let n):
			try c.encode(n)
		case .string(let s):
			try c.encode(s)
		}
	}
}

// First-pass peek at an incoming line: enough to route it without knowing payload types.
public struct RPCPeek: Decodable {
	public var jsonrpc: String?
	public var id: RPCID?
	public var method: String?
	public var error: RPCErrorBody?

	public var isNotification: Bool { method != nil && id == nil }
	public var isRequest: Bool { method != nil && id != nil }
	public var isResponse: Bool { method == nil && id != nil }
}

public struct RPCCall<P: Codable>: Codable {
	public var jsonrpc: String
	public var id: RPCID?
	public var method: String
	public var params: P?

	public init(id: RPCID?, method: String, params: P?) {
		self.jsonrpc = JSONRPC.version
		self.id = id
		self.method = method
		self.params = params
	}
}

public struct RPCResult<R: Codable>: Codable {
	public var jsonrpc: String
	public var id: RPCID
	public var result: R

	public init(id: RPCID, result: R) {
		self.jsonrpc = JSONRPC.version
		self.id = id
		self.result = result
	}
}

public struct RPCErrorBody: Codable, Equatable, Sendable {
	public struct ErrorData: Codable, Equatable, Sendable {
		public var machmanCode: String?

		public init(machmanCode: String?) {
			self.machmanCode = machmanCode
		}
	}

	public var code: Int
	public var message: String
	public var data: ErrorData?

	public init(code: Int, message: String, data: ErrorData? = nil) {
		self.code = code
		self.message = message
		self.data = data
	}

	public init(_ error: MachmanError) {
		self.code = JSONRPC.applicationError
		self.message = error.message
		self.data = ErrorData(machmanCode: error.code.rawValue)
	}

	// The MachmanError this body carries (application errors round-trip their code; a method
	// the peer doesn't know reads as unsupported, so a client can fall back).
	public var machmanError: MachmanError {
		if code == JSONRPC.methodNotFound, data?.machmanCode == nil {
			return MachmanError(code: .unsupported, message: message)
		}
		let code = data?.machmanCode.flatMap { MachmanError.Code(rawValue: $0) }
		return MachmanError(code: code ?? .internalError, message: message)
	}
}

public struct RPCErrorReply: Codable {
	public var jsonrpc: String
	public var id: RPCID?
	public var error: RPCErrorBody

	public init(id: RPCID?, error: RPCErrorBody) {
		self.jsonrpc = JSONRPC.version
		self.id = id
		self.error = error
	}
}

// Empty params/results ({}). Tolerates any object on decode.
public struct RPCEmpty: Codable, Equatable, Sendable {
	public init() {}
	public init(from decoder: Decoder) throws {}
	public func encode(to encoder: Encoder) throws {
		_ = encoder.container(keyedBy: NeverKey.self)
	}

	private enum NeverKey: CodingKey {}
}

// An explicit JSON null result ("result":null) — synthesized Codable would omit the key.
public struct JSONNull: Codable, Equatable, Sendable {
	public init() {}
	public init(from decoder: Decoder) throws {}
	public func encode(to encoder: Encoder) throws {
		var c = encoder.singleValueContainer()
		try c.encodeNil()
	}
}
