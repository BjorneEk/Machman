//
//  CallDeadlineClockTests.swift
//  MachmanClientTests
//
//  Q40: a call's deadline ran on the wall clock only, so the daemon's checks that a stalled
//  vmhost costs one short deadline measured elapsed time — and failed when load stretched it.
//  A connection takes the clock its deadlines run on (ContinuousClock unless a test passes
//  one), and RemoteMachman passes its own to the connection and its hello.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
import MachmanClient

@MainActor
private final class Outcome {
	var ended = false
}

@MainActor
struct CallDeadlineClockTests {
	@Test("Q40: a call's deadline fires when the connection's clock passes it, never before")
	func aCallsDeadlineRunsOnTheConnectionsClock() async throws {
		let peer = try ScriptedPeer()
		defer { peer.close() }
		let clock = TestClock()
		let connection = try RPCConnection(socketPath: peer.socketPath, clock: clock)
		let outcome = Outcome()
		let call = Task { @MainActor in
			defer { outcome.ended = true }
			_ = try await connection.call(
				.vmList, RPCEmpty?.none, expecting: RPCEmpty.self, deadline: .milliseconds(300))
		}
		await peer.waitForRequests(1)
		#expect(await eventually { clock.armed == [.milliseconds(300)] })
		clock.advance(by: .milliseconds(299))
		#expect(await settled { outcome.ended })
		#expect(!outcome.ended)   // a millisecond short of its deadline: still waiting
		clock.advance(by: .milliseconds(1))
		do {
			try await call.cancellableValue()
			Issue.record("the call ended without an answer or its deadline")
		} catch let error as MachmanError {
			#expect(error.code == .timeout)
			#expect(error.message == "No answer within 300 ms")
		}
		await connection.disconnect()
	}

	@Test("Q40: a hello's deadline runs on the client's clock")
	func aHellosDeadlineRunsOnTheClientsClock() async throws {
		let peer = try ScriptedPeer(helloAPIVersion: nil)   // never answers hello
		defer { peer.close() }
		let clock = TestClock()
		let connect = Task {
			try await RemoteMachman(
				socketPath: peer.socketPath, clientName: "q40", helloDeadline: .milliseconds(200),
				clock: clock)
		}
		#expect(await eventually { clock.armed == [.milliseconds(200)] })
		clock.advance(by: .milliseconds(200))
		do {
			_ = try await connect.cancellableValue()
			Issue.record("connected without a hello")
		} catch let error as MachmanError {
			#expect(error.code == .timeout)
		}
	}
}
