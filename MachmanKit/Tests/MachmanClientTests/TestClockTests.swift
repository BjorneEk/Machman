//
//  TestClockTests.swift
//  MachmanClientTests
//
//  Q40: the clock the router and client tests move by hand (MachmanTestSupport's TestClock).
//  A sleeper wakes only once an advance reaches its deadline, a cancelled one ends at once,
//  and what is armed reads as each sleeper's time left.
//

import Testing
import Foundation
import MachmanTestSupport

@MainActor
private final class Woken {
	var done = false
}

@MainActor
struct TestClockTests {
	@Test("Q40: a test clock's sleeper wakes only once the clock passes its deadline")
	func aSleeperWakesOnlyAtItsDeadline() async throws {
		let clock = TestClock()
		let woken = Woken()
		let sleeper = Task { @MainActor in
			try await clock.sleep(for: .milliseconds(300))
			woken.done = true
		}
		#expect(await eventually { clock.armed == [.milliseconds(300)] })
		clock.advance(by: .milliseconds(200))
		#expect(await settled { woken.done })
		#expect(!woken.done)
		#expect(clock.armed == [.milliseconds(100)])
		clock.advance(by: .milliseconds(100))
		try await sleeper.cancellableValue()
		#expect(woken.done)
		#expect(clock.armed.isEmpty)
		#expect(clock.everArmed == [.milliseconds(300)])

		// A deadline already reached returns at once, and arms nothing.
		try await clock.sleep(until: clock.now)
		#expect(clock.everArmed == [.milliseconds(300)])
	}

	@Test("Q40: a cancelled sleeper on the test clock ends at once")
	func aCancelledSleeperEndsAtOnce() async {
		let clock = TestClock()
		let sleeper = Task { try await clock.sleep(for: .seconds(1)) }
		#expect(await eventually { clock.armed == [.seconds(1)] })
		sleeper.cancel()
		let result = await sleeper.result
		#expect(throws: CancellationError.self) { try result.get() }
		#expect(clock.armed.isEmpty)

		// Cancelled before it armed: it never sleeps.
		let early = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			try await clock.sleep(for: .seconds(1))
		}
		let earlyResult = await early.result
		#expect(throws: CancellationError.self) { try earlyResult.get() }
		#expect(clock.armed.isEmpty)
	}

	// What a test's time limit does to a check stuck on a deadline nothing moves past: the
	// cancelled wait cancels the work, which wakes and ends instead of hanging the run.
	@Test("Q40: a cancelled wait for a task ends the task asleep on a test clock")
	func aCancelledWaitEndsTheSleepingTask() async {
		let clock = TestClock()
		let sleeper = Task { try await clock.sleep(for: .seconds(3600)) }
		let waiter = Task { try await sleeper.cancellableValue() }
		#expect(await eventually { clock.armed == [.seconds(3600)] })
		waiter.cancel()
		let result = await sleeper.result
		#expect(throws: CancellationError.self) { try result.get() }
		#expect(clock.armed.isEmpty)
		_ = await waiter.result
	}
}
