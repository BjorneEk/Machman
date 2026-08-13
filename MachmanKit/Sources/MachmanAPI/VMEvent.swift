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
	// A copy of vm (the TARGET name) in flight: bytes done vs total. ETA is consumer math.
	case copyProgress(vm: String, copiedBytes: UInt64, totalBytes: UInt64)
	// A long-running operation changed (started, progressed, or reached a terminal state).
	// Resync after reconnect via host.operations — events have no replay.
	case operationChanged(op: OperationInfo)
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
		case copiedBytes
		case totalBytes
		case op
	}

	private enum Kind: String {
		case stateChanged
		case listChanged
		case installPhaseChanged
		case log
		case copyProgress
		case operationChanged
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
		case .copyProgress:
			self = .copyProgress(
				vm: try c.decode(String.self, forKey: .vm),
				copiedBytes: try c.decode(UInt64.self, forKey: .copiedBytes),
				totalBytes: try c.decode(UInt64.self, forKey: .totalBytes))
		case .operationChanged:
			self = .operationChanged(op: try c.decode(OperationInfo.self, forKey: .op))
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
		case .copyProgress(let vm, let copiedBytes, let totalBytes):
			try c.encode(Kind.copyProgress.rawValue, forKey: .type)
			try c.encode(vm, forKey: .vm)
			try c.encode(copiedBytes, forKey: .copiedBytes)
			try c.encode(totalBytes, forKey: .totalBytes)
		case .operationChanged(let op):
			try c.encode(Kind.operationChanged.rawValue, forKey: .type)
			try c.encode(op, forKey: .op)
		case .unknown(let type):
			try c.encode(type, forKey: .type)
		}
	}
}
