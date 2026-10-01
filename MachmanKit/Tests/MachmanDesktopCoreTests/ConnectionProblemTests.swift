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

	// One title per problem, and a remedy where the buttons don't already say it.
	@Test func eachProblemSaysWhatToDo() {
		let unreachable = ConnectionProblem(kind: .unreachable, detail: "")
		#expect(unreachable.title == "Can't reach Machman Agent")
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
