//
//  ConnectionProblemTests.swift
//  MachmanDesktopCoreTests
//
//  Why a connect attempt failed decides what the connect screen offers: can't reach (launch
//  the agent), not answering (quit the hung one), or a different api version. The detail is
//  one sentence in words (W4): no socket path, no "MachmanAgent"/"daemon", no RPC method.
//

import Testing
import Foundation
import MachmanAPI
import MachmanClient
@testable import MachmanDesktopCore

struct ConnectionProblemTests {

	@Test func aRefusedOrLostConnectionIsUnreachable() {
		let refused = ConnectionProblem.classify(RPCConnection.ConnectionError.connectFailed(
			"/var/empty/machman.sock", ECONNREFUSED))
		#expect(refused.kind == .unreachable)
		#expect(refused.detail == "It isn\u{2019}t running.")
		let missing = ConnectionProblem.classify(RPCConnection.ConnectionError.connectFailed(
			"/var/empty/machman.sock", ENOENT))
		#expect(missing.detail == "It isn\u{2019}t running.")
		let denied = ConnectionProblem.classify(RPCConnection.ConnectionError.connectFailed(
			"/var/empty/machman.sock", EACCES))
		#expect(denied == ConnectionProblem(kind: .unreachable, detail: "Permission denied."))
		let lost = ConnectionProblem.classify(RPCConnection.ConnectionError.disconnected)
		#expect(lost.kind == .unreachable)
		#expect(lost.detail == "The connection closed before it answered.")
	}

	@Test func aTimeoutIsNotAnswering() {
		let problem = ConnectionProblem.classify(MachmanError(
			code: .timeout, message: "no reply to machman.hello after 10s"))
		#expect(problem == ConnectionProblem(
			kind: .notAnswering, detail: "It accepted the connection but didn\u{2019}t answer."))
	}

	@Test func aMismatchIsIncompatible() {
		let problem = ConnectionProblem.classify(
			RemoteMachman.APIVersionMismatch(daemonAPI: 2, clientAPI: 1))
		#expect(problem == ConnectionProblem(
			kind: .incompatible, detail: "It speaks API version 2, and this app needs version 1."))
	}

	// One title per problem, and a remedy where the buttons don't already say it.
	@Test func eachProblemSaysWhatToDo() {
		let unreachable = ConnectionProblem(kind: .unreachable, detail: "")
		#expect(unreachable.title == "Can\u{2019}t reach Machman Agent")
		#expect(unreachable.hint == nil)
		let silent = ConnectionProblem(kind: .notAnswering, detail: "")
		#expect(silent.title == "Machman Agent is not answering")
		#expect(silent.hint
			== "Choose Quit Machman Agent from its menu-bar item, then click Retry.")
		let other = ConnectionProblem(kind: .incompatible, detail: "")
		#expect(other.title == "The running Machman Agent is a different version")
		#expect(other.hint == "Choose Quit Machman Agent from its menu-bar item, then click "
			+ "Retry to start the one inside this app.")
	}

	@Test func anyOtherFailureIsUnreachableWithItsMessage() {
		let problem = ConnectionProblem.classify(
			MachmanError(code: .invalidState, message: "the agent is shutting down"))
		#expect(problem == ConnectionProblem(
			kind: .unreachable, detail: "the agent is shutting down"))
	}
}
