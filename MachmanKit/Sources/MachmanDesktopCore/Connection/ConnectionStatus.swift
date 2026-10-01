//
//  ConnectionStatus.swift
//  MachmanDesktopCore
//
//  What the desktop's connect screen shows: connecting, connected, or stopped on a problem
//  the user can act on. The problem's kind decides the remedy, so a failed attempt is
//  classified by WHY it failed — the agent isn't there, it doesn't answer, or it speaks
//  another wire generation — never lumped into one "not reachable".
//

import Foundation
import MachmanAPI
import MachmanClient

public enum ConnectionStatus: Equatable {
	case connecting
	case connected(daemonVersion: String)
	case unavailable(ConnectionProblem)
}

public struct ConnectionProblem: Equatable {
	public enum Kind: Equatable {
		case unreachable    // no socket, refused, or the connection closed under us
		case notAnswering   // the agent accepted but never answered (hung)
		case incompatible   // the agent speaks another api version
	}

	public var kind: Kind
	public var detail: String   // the underlying error, as logged

	public init(kind: Kind, detail: String) {
		self.kind = kind
		self.detail = detail
	}

	public static func classify(_ error: Error) -> ConnectionProblem {
		switch error {
		case let mismatch as RemoteMachman.APIVersionMismatch:
			return ConnectionProblem(kind: .incompatible, detail: mismatch.description)
		case let error as MachmanError where error.code == .timeout:
			return ConnectionProblem(kind: .notAnswering, detail: error.message)
		case let error as MachmanError:
			return ConnectionProblem(kind: .unreachable, detail: error.message)
		default:
			// RPCConnection.ConnectionError (connect refused, connection lost) and anything
			// unforeseen: the agent is, as far as this client can tell, not there.
			return ConnectionProblem(kind: .unreachable, detail: String(describing: error))
		}
	}
}
