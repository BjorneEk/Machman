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

	// What the connect screen says: the problem, then the one thing to do about it.
	public var title: String {
		switch kind {
		case .unreachable: return "Can't reach Machman Agent"
		case .notAnswering: return "Machman Agent is not answering"
		case .incompatible: return "The running Machman Agent is a different version"
		}
	}

	// nil when the screen's own Launch Daemon and Retry buttons say it all.
	public var hint: String? {
		switch kind {
		case .unreachable:
			return nil
		case .notAnswering:
			return "Choose Quit Machman Agent from its menu-bar item, then click Retry."
		case .incompatible:
			return "Choose Quit Machman Agent from its menu-bar item, then click Retry to "
				+ "start the one inside this app."
		}
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
