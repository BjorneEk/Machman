//
//  TestClock.swift
//  MachmanTestSupport
//
//  A clock that moves only when a test advances it (Q40). Code that takes a clock — the call
//  deadlines of an RPC connection, the router's deadlines and retry timers — sleeps on it, and
//  the test reads what is armed and moves time by the deadline under test: a check says "the
//  deadline armed was 300 ms and one advance by it answered the call", never "it took under
//  2 s", which a loaded machine breaks. Nothing wakes on its own: a sleep no test advances past
//  stays asleep until it is cancelled.
//

import Foundation

public final class TestClock: Clock, @unchecked Sendable {
	public struct Instant: InstantProtocol, CustomStringConvertible {
		public let offset: Duration

		public func advanced(by duration: Duration) -> Instant {
			Instant(offset: offset + duration)
		}

		public func duration(to other: Instant) -> Duration {
			other.offset - offset
		}

		public static func < (lhs: Instant, rhs: Instant) -> Bool {
			lhs.offset < rhs.offset
		}

		public var description: String { "\(offset)" }
	}

	private struct Sleeper {
		let id: UInt64
		let deadline: Instant
		let continuation: CheckedContinuation<Void, Error>
	}

	private let lock = NSLock()
	private var current = Instant(offset: .zero)
	private var sleepers: [Sleeper] = []
	private var cancelledBeforeArming: Set<UInt64> = []
	private var lastID: UInt64 = 0
	private var lengths: [Duration] = []

	public init() {}

	public var now: Instant { lock.withLock { current } }

	public var minimumResolution: Duration { .zero }

	// What is asleep now: each sleeper's time left, soonest first.
	public var armed: [Duration] {
		lock.withLock { sleepers.map { current.duration(to: $0.deadline) }.sorted() }
	}

	// Every sleep that ever waited on this clock, by the length it asked for, in order.
	public var everArmed: [Duration] { lock.withLock { lengths } }

	public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
		try Task.checkCancellation()
		let id: UInt64 = lock.withLock {
			lastID += 1
			return lastID
		}
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				enum Outcome { case asleep, due, cancelled }
				let outcome: Outcome = lock.withLock {
					if cancelledBeforeArming.remove(id) != nil { return .cancelled }
					if deadline <= current { return .due }
					sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
					lengths.append(current.duration(to: deadline))
					return .asleep
				}
				switch outcome {
				case .asleep: break
				case .due: continuation.resume()
				case .cancelled: continuation.resume(throwing: CancellationError())
				}
			}
		} onCancel: {
			let sleeper: Sleeper? = lock.withLock {
				guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
					cancelledBeforeArming.insert(id)
					return nil
				}
				return sleepers.remove(at: index)
			}
			sleeper?.continuation.resume(throwing: CancellationError())
		}
	}

	// Moves time on by `duration` and wakes every sleeper whose deadline it reached, soonest
	// first. A sleep armed by what they then run waits for the next advance.
	public func advance(by duration: Duration) {
		let due: [Sleeper] = lock.withLock {
			current = current.advanced(by: duration)
			let reached = sleepers.filter { $0.deadline <= current }
			sleepers.removeAll { $0.deadline <= current }
			return reached.sorted { $0.deadline < $1.deadline }
		}
		for sleeper in due {
			sleeper.continuation.resume()
		}
	}
}

// A task's value that cancels the task when the test awaiting it is cancelled: a test's time
// limit then ends work left asleep on a TestClock nothing advances, instead of hanging the run
// (a Task's plain value ignores its waiter's cancellation).
extension Task where Failure == Error {
	public func cancellableValue() async throws -> Success {
		try await withTaskCancellationHandler {
			try await value
		} onCancel: {
			cancel()
		}
	}
}

extension Task where Failure == Never {
	public func cancellableValue() async -> Success {
		await withTaskCancellationHandler {
			await value
		} onCancel: {
			cancel()
		}
	}
}
