//
//  OwnThreadTests.swift
//  MachmanClientTests
//
//  Q43: the thread MachmanTestSupport hands a test's blocking work to. The work runs there —
//  never on the main thread or the cooperative pool — as part of its test, so the checks in it
//  land in the test; a main-actor test's closure leaves the main actor too.
//

import Testing
import Foundation
import MachmanTestSupport

// Where the calling code runs: its thread's name, and whether that is the main thread.
private func here() -> (thread: String?, main: Bool) {
	(Thread.current.name, Thread.isMainThread)
}

struct OwnThreadTests {
	@Test("Q43: work on the own thread runs off the main thread and the pool, inside its test")
	func workRunsOnTheOwnThread() async {
		let test = Test.current?.id
		let (place, inTest) = await onOwnThread { (here(), Test.current?.id) }
		#expect(place.thread == OwnThread.threadName)
		#expect(!place.main)
		#expect(test != nil && inTest == test)
	}

	@Test("Q43: a main-actor test's closure leaves the main actor on the own thread")
	@MainActor func aMainActorClosureLeavesTheMainActor() async {
		let place = await onOwnThread { here() }
		#expect(place.thread == OwnThread.threadName)
		#expect(!place.main)
	}
}
