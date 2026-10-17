//
//  OwnThread.swift
//  MachmanTestSupport
//
//  A test's blocking work — a subprocess the engine spawns, a fork, a file sync, a checksum
//  over megabytes — on a thread of its own (Q43). On the main actor it held the engine pass's
//  main thread for up to 2 s under load; on the cooperative pool it starves the Task-based
//  tests beside it (Subprocess's lesson). The work runs as part of the calling task, through a
//  task executor preference rather than a detached thread, so its #expect and #require land in
//  the test as anywhere else. One thread for the whole run: the blocking work of tests side by
//  side takes turns, as Subprocess's children do. A VMTestDir redirect inside stays synchronous
//  (it is never held across an await).
//

import Foundation

public final class OwnThread: TaskExecutor, @unchecked Sendable {
	public static let shared = OwnThread()

	// Its thread's name, for a test that checks where work ran.
	public static let threadName = "machman-test-own-thread"

	private let condition = NSCondition()
	private var jobs: [UnownedJob] = []

	private init() {
		let thread = Thread { [unowned self] in self.run() }
		thread.name = Self.threadName
		thread.start()
	}

	public func enqueue(_ job: consuming ExecutorJob) {
		let job = UnownedJob(job)
		condition.lock()
		jobs.append(job)
		condition.signal()
		condition.unlock()
	}

	public func asUnownedTaskExecutor() -> UnownedTaskExecutor {
		UnownedTaskExecutor(ordinary: self)
	}

	private func run() {
		while true {
			condition.lock()
			while jobs.isEmpty { condition.wait() }
			let job = jobs.removeFirst()
			condition.unlock()
			job.runSynchronously(on: asUnownedTaskExecutor())
		}
	}
}

// `body` on the own thread, never on the main actor's or the pool's. It is @Sendable, so a
// main-actor test's closure leaves the main actor too.
public func onOwnThread<T>(_ body: @Sendable () async throws -> T) async rethrows -> T {
	try await withTaskExecutorPreference(OwnThread.shared) { try await body() }
}
