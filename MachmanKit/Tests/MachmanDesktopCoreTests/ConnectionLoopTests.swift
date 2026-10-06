//
//  ConnectionLoopTests.swift
//  MachmanDesktopCoreTests
//
//  The desktop's connect loop over scripted attempts: it stops on its bounds and says why
//  (P1), launches the agent at most once per cycle, never attaches a session whose attempt
//  was abandoned or that died on the way in (P4), fails an attempt whose events subscription
//  fails (P13), and reconnects after a drop unless the agent keeps dropping right away.
//

import Testing
import Foundation
import MachmanAPI
import MachmanClient
import MachmanTestSupport
@testable import MachmanDesktopCore

// A stop is awaited on the loop's own status report (LoopRecorder.stopped), never against a wall
// clock: a 5 s deadline failed at load ~13. The suite's time limit bounds a hang.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConnectionLoopTests {

	// P1: before, every failed hello also reported a drop, and the drop restarted the loop
	// with a fresh counter and another launch — forever. Now the bound holds even then.
	@Test func unreachableStopsAfterTheBoundAndLaunchesOnce() async {
		let connector = FakeConnector()
		connector.otherwise = .failure(FakeConnector.refused, reportsDrop: true)
		let recorder = LoopRecorder()
		let loop = makeLoop(connector, recorder, policy: .fast(maxAttempts: 5))
		loop.start()
		await recorder.stopped()
		#expect(loop.status.problemKind == .unreachable)
		#expect(connector.connects == 5)
		#expect(connector.launches == 1)
		try? await Task.sleep(for: .milliseconds(50))
		#expect(connector.connects == 5)
		#expect(recorder.attached.isEmpty)
		#expect(recorder.detaches == 0)
	}

	@Test func aSilentAgentStopsAfterTwoTimeouts() async {
		let connector = FakeConnector()
		connector.otherwise = .failure(FakeConnector.silent)
		let recorder = LoopRecorder()
		let loop = makeLoop(connector, recorder)
		loop.start()
		await recorder.stopped()
		#expect(loop.status.problemKind == .notAnswering)
		#expect(connector.connects == 2)
		#expect(connector.launches == 0)
	}

	@Test func aMismatchStopsAtOnce() async {
		let connector = FakeConnector()
		connector.otherwise = .failure(FakeConnector.mismatch)
		let recorder = LoopRecorder()
		let loop = makeLoop(connector, recorder)
		loop.start()
		await recorder.stopped()
		#expect(loop.status == .unavailable(ConnectionProblem(
			kind: .incompatible, detail: "It speaks API version 2, and this app needs version 1.")))
		#expect(connector.connects == 1)
		#expect(connector.launches == 0)
	}

	// P4: an attempt that outlived its cycle disconnects what it got and never attaches, and
	// that session's drop leaves the current one alone.
	@Test func aCancelledAttemptThatSucceedsLaterNeverAttaches() async {
		let connector = FakeConnector()
		let a = FakeSession("A")
		let b = FakeSession("B")
		connector.script = [.suspended, .session(b)]
		let recorder = LoopRecorder()
		let loop = makeLoop(connector, recorder)
		loop.start()
		#expect(await eventually(timeout: .seconds(5)) { connector.parkedCount == 1 })
		loop.retry()
		#expect(await eventually(timeout: .seconds(5)) { recorder.attachedNames == ["B"] })
		connector.resumeParked(with: a)
		#expect(await eventually(timeout: .seconds(5)) { a.disconnects == 1 })
		try? await Task.sleep(for: .milliseconds(50))
		#expect(recorder.attachedNames == ["B"])
		#expect(recorder.detaches == 0)
		#expect(loop.status == .connected(daemonVersion: "1.0.10"))
		#expect(b.disconnects == 0)
	}

	// P13's events half: a session whose subscription failed would run event-less.
	@Test func aFailedSubscribeFailsTheAttempt() async {
		let connector = FakeConnector()
		let first = FakeSession("first")
		first.subscribeError = MachmanError(
			code: .timeout, message: "no reply to events.subscribe after 30s")
		let second = FakeSession("second")
		connector.script = [.session(first), .session(second)]
		let recorder = LoopRecorder()
		let loop = makeLoop(connector, recorder)
		loop.start()
		#expect(await eventually(timeout: .seconds(5)) { recorder.attachedNames == ["second"] })
		#expect(first.disconnects == 1)
		#expect(second.subscribes == 1)
		#expect(recorder.detaches == 0)
	}

	@Test func aSessionThatDroppedWhileConnectingIsNotAttached() async {
		let connector = FakeConnector()
		let dead = FakeSession("dead")
		let live = FakeSession("live")
		connector.script = [.droppedSession(dead), .session(live)]
		let recorder = LoopRecorder()
		let loop = makeLoop(connector, recorder)
		loop.start()
		#expect(await eventually(timeout: .seconds(5)) { recorder.attachedNames == ["live"] })
		#expect(dead.disconnects == 1)
		#expect(recorder.detaches == 0)
		#expect(connector.launches == 1)   // a drop on the way in reads as can't-reach
	}

	@Test func aDroppedSessionReconnects() async {
		let connector = FakeConnector()
		let a = FakeSession("A")
		let b = FakeSession("B")
		connector.script = [.session(a), .session(b)]
		let recorder = LoopRecorder()
		let loop = makeLoop(connector, recorder)
		loop.start()
		#expect(await eventually(timeout: .seconds(5)) { recorder.attachedNames == ["A"] })
		a.die()
		#expect(await eventually(timeout: .seconds(5)) { recorder.attachedNames == ["A", "B"] })
		#expect(recorder.detaches == 1)
		#expect(connector.launches == 0)
		#expect(loop.status == .connected(daemonVersion: "1.0.10"))
	}

	// An agent that dies right after every connect would otherwise relaunch and reconnect
	// forever — the P1 class after the hello.
	@Test func quickDropsStopTheLoop() async {
		let connector = FakeConnector()
		let sessions = (1...4).map { FakeSession("S\($0)") }
		connector.script = sessions.map { .session($0) }
		let recorder = LoopRecorder()
		let loop = makeLoop(connector, recorder, policy: .fast(healthySession: .seconds(60)))
		loop.start()
		for (index, session) in sessions.prefix(3).enumerated() {
			#expect(await eventually(timeout: .seconds(5)) {
				recorder.attached.count == index + 1
			})
			session.die()
		}
		await recorder.stopped()
		#expect(loop.status.problemKind == .unreachable)
		try? await Task.sleep(for: .milliseconds(50))
		#expect(connector.connects == 3)
		#expect(recorder.detaches == 3)
		loop.retry()
		#expect(await eventually(timeout: .seconds(5)) { recorder.attachedNames.last == "S4" })
	}

	@Test func retryAfterUnavailableStartsAFreshCycle() async {
		let connector = FakeConnector()
		connector.otherwise = .failure(FakeConnector.silent)
		let recorder = LoopRecorder()
		let loop = makeLoop(connector, recorder)
		loop.start()
		await recorder.stopped()
		let session = FakeSession("S", daemonVersion: "1.0.11")
		connector.script = [.session(session)]
		loop.retry()
		#expect(loop.status == .connecting)   // the screen leaves the error at once
		#expect(await eventually(timeout: .seconds(5)) { recorder.attachedNames == ["S"] })
		#expect(loop.status == .connected(daemonVersion: "1.0.11"))
	}

	// Launch Daemon launches the agent itself, then retries: that cycle must not launch it
	// a second time.
	@Test func retryAfterALaunchDoesNotLaunchAgain() async {
		let connector = FakeConnector()
		let recorder = LoopRecorder()
		let loop = makeLoop(connector, recorder, policy: .fast(maxAttempts: 3))
		loop.start()
		await recorder.stopped()
		#expect(connector.connects == 3)
		#expect(connector.launches == 1)
		loop.retry(launched: true)
		await recorder.stopped(times: 2)
		#expect(loop.status.problemKind == .unreachable)
		#expect(connector.connects == 6)
		#expect(connector.launches == 1)
	}

	// P12: what a drop cut off reaches the next attach, once.
	@Test func interruptedCallsReachTheNextAttach() async {
		let connector = FakeConnector()
		let a = FakeSession("A")
		a.interrupted = [InterruptedCall(method: .start, vm: "Debian")]
		let b = FakeSession("B")
		let c = FakeSession("C")
		connector.script = [.session(a), .session(b), .session(c)]
		let recorder = LoopRecorder()
		let loop = makeLoop(connector, recorder)
		loop.start()
		#expect(await eventually(timeout: .seconds(5)) { recorder.attachedNames == ["A"] })
		a.die()
		#expect(await eventually(timeout: .seconds(5)) { recorder.attachedNames == ["A", "B"] })
		b.die()
		#expect(await eventually(timeout: .seconds(5)) {
			recorder.attachedNames == ["A", "B", "C"]
		})
		#expect(recorder.carried == [
			[], [InterruptedCall(method: .start, vm: "Debian")], [],
		])
	}

	// A drop whose reconnect fails keeps its record through the stopped cycle and the
	// user's Retry.
	@Test func interruptedCallsSurviveAStoppedCycle() async {
		let connector = FakeConnector()
		let a = FakeSession("A")
		a.interrupted = [InterruptedCall(method: .vmDelete, vm: "Alpine")]
		connector.script = [.session(a)]
		connector.otherwise = .failure(FakeConnector.silent)
		let recorder = LoopRecorder()
		let loop = makeLoop(connector, recorder)
		loop.start()
		#expect(await eventually(timeout: .seconds(5)) { recorder.attachedNames == ["A"] })
		a.die()
		await recorder.stopped()
		connector.script = [.session(FakeSession("B"))]
		loop.retry()
		#expect(await eventually(timeout: .seconds(5)) { recorder.attachedNames == ["A", "B"] })
		#expect(recorder.carried.last == [InterruptedCall(method: .vmDelete, vm: "Alpine")])
	}

	@Test func startIsANoOpWhileConnected() async {
		let connector = FakeConnector()
		connector.script = [.session(FakeSession("A"))]
		let recorder = LoopRecorder()
		let loop = makeLoop(connector, recorder)
		loop.start()
		#expect(await eventually(timeout: .seconds(5)) { recorder.attachedNames == ["A"] })
		loop.start()
		loop.retry()
		try? await Task.sleep(for: .milliseconds(50))
		#expect(connector.connects == 1)
		#expect(recorder.attachedNames == ["A"])
	}
}
