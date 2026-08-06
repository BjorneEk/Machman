//
//  VMEvent.swift
//  MachmanAPI
//
//  Events broadcast by the daemon to every subscriber (GUI, menu bar, CLI). Hand-written
//  tagged Codable — {"type": "...", ...} — so the wire shape is stable and obvious to
//  non-Swift clients; unknown types decode to .unknown instead of failing the stream.
//

import Foundation

public enum VMEvent: Sendable, Equatable {
	case stateChanged(vm: String, state: VMState)
	case listChanged
	case installPhaseChanged(vm: String, phase: InstallPhase)
	case log(vm: String?, level: LogLevel, message: String)
	case unknown(type: String)
}

extension VMEvent: Codable {
	private enum CodingKeys: String, CodingKey {
		case type
		case vm
		case state
		case phase
		case level
		case message
	}

	private enum Kind: String {
		case stateChanged
		case listChanged
		case installPhaseChanged
		case log
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		let type = try c.decode(String.self, forKey: .type)
		switch Kind(rawValue: type) {
		case .stateChanged:
			self = .stateChanged(
				vm: try c.decode(String.self, forKey: .vm),
				state: try c.decode(VMState.self, forKey: .state))
		case .listChanged:
			self = .listChanged
		case .installPhaseChanged:
			self = .installPhaseChanged(
				vm: try c.decode(String.self, forKey: .vm),
				phase: try c.decode(InstallPhase.self, forKey: .phase))
		case .log:
			self = .log(
				vm: try c.decodeIfPresent(String.self, forKey: .vm),
				level: try c.decode(LogLevel.self, forKey: .level),
				message: try c.decode(String.self, forKey: .message))
		case nil:
			self = .unknown(type: type)
		}
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .stateChanged(let vm, let state):
			try c.encode(Kind.stateChanged.rawValue, forKey: .type)
			try c.encode(vm, forKey: .vm)
			try c.encode(state, forKey: .state)
		case .listChanged:
			try c.encode(Kind.listChanged.rawValue, forKey: .type)
		case .installPhaseChanged(let vm, let phase):
			try c.encode(Kind.installPhaseChanged.rawValue, forKey: .type)
			try c.encode(vm, forKey: .vm)
			try c.encode(phase, forKey: .phase)
		case .log(let vm, let level, let message):
			try c.encode(Kind.log.rawValue, forKey: .type)
			try c.encodeIfPresent(vm, forKey: .vm)
			try c.encode(level, forKey: .level)
			try c.encode(message, forKey: .message)
		case .unknown(let type):
			try c.encode(type, forKey: .type)
		}
	}
}
