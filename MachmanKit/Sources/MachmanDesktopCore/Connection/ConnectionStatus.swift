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
	// One sentence about the cause, in words ("It isn’t running."); the raw error, socket
	// path and all, goes to the log at each failed attempt.
	public var detail: String

	public init(kind: Kind, detail: String) {
		self.kind = kind
		self.detail = detail
	}

	// What the connect screen says: the problem, then the one thing to do about it.
	public var title: String {
		switch kind {
		case .unreachable: return "Can’t reach Machman Agent"
		case .notAnswering: return "Machman Agent is not answering"
		case .incompatible: return "The running Machman Agent is a different version"
		}
	}

	// nil when the screen's own Launch Machman Agent and Retry buttons say it all.
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

	// The detail is a caption under the title, about the agent the title names ("It …").
	public static func classify(_ error: Error) -> ConnectionProblem {
		switch error {
		case let mismatch as RemoteMachman.APIVersionMismatch:
			return ConnectionProblem(
				kind: .incompatible,
				detail: "It speaks API version \(mismatch.daemonAPI), and this app needs "
					+ "version \(mismatch.clientAPI).")
		case let error as MachmanError where error.code == .timeout:
			return ConnectionProblem(
				kind: .notAnswering, detail: "It accepted the connection but didn’t answer.")
		case let error as MachmanError:
			return ConnectionProblem(kind: .unreachable, detail: error.message)
		case RPCConnection.ConnectionError.connectFailed(_, let err):
			// No socket, or nothing listening on it: the agent isn't there.
			let detail = err == ENOENT || err == ECONNREFUSED
				? "It isn’t running." : "\(String(cString: strerror(err)))."
			return ConnectionProblem(kind: .unreachable, detail: detail)
		case RPCConnection.ConnectionError.disconnected:
			return ConnectionProblem(
				kind: .unreachable, detail: "The connection closed before it answered.")
		default:
			// Anything unforeseen: the agent is, as far as this client can tell, not there.
			return ConnectionProblem(
				kind: .unreachable, detail: MachmanError.userMessage(for: error))
		}
	}
}
