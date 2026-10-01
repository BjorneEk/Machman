//
//  ConnectionProblemTests.swift
//  MachmanDesktopCoreTests
//
//  Why a connect attempt failed decides what the connect screen offers: can't reach (launch
//  the agent), not answering (quit the hung one), or a different api version.
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
		#expect(refused.detail
			== "cannot reach MachmanAgent at /var/empty/machman.sock: Connection refused")
		let lost = ConnectionProblem.classify(RPCConnection.ConnectionError.disconnected)
		#expect(lost.kind == .unreachable)
		#expect(lost.detail == "the daemon connection was lost")
	}

	@Test func aTimeoutIsNotAnswering() {
		let problem = ConnectionProblem.classify(MachmanError(
			code: .timeout, message: "no reply to machman.hello after 10s"))
		#expect(problem == ConnectionProblem(
			kind: .notAnswering, detail: "no reply to machman.hello after 10s"))
	}

	@Test func aMismatchIsIncompatible() {
		let problem = ConnectionProblem.classify(
			RemoteMachman.APIVersionMismatch(daemonAPI: 2, clientAPI: 1))
		#expect(problem == ConnectionProblem(
			kind: .incompatible, detail: "daemon speaks api v2, client needs v1"))
	}

	@Test func anyOtherFailureIsUnreachableWithItsMessage() {
		let problem = ConnectionProblem.classify(
			MachmanError(code: .invalidState, message: "the agent is shutting down"))
		#expect(problem == ConnectionProblem(
			kind: .unreachable, detail: "the agent is shutting down"))
	}
}
