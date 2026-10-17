//
//  RetryScheduler.swift
//  MachmanDesktopCore
//
//  A store's retry of a read that failed (P13, Q32): one retry pending at a time, waiting
//  out its RetryBackoff. A retry clears itself before it runs, so one that fails again
//  schedules the next; a success resets the backoff and drops whatever was pending. The
//  VM list (VMStore) and the operations mirror (OperationsStore) share it.
//

import Foundation

@MainActor
final class RetryScheduler {
	private var backoff: RetryBackoff
	private var task: Task<Void, Never>?

	init(delays: [Duration] = RetryBackoff.standardDelays) {
		backoff = RetryBackoff(delays: delays)
	}

	var isPending: Bool { task != nil }

	// `retry` runs after the next wait, unless one is already pending or cancel() comes first.
	func schedule(_ retry: @escaping @MainActor () async -> Void) {
		guard task == nil else { return }
		let delay = backoff.next()
		task = Task { [weak self] in
			try? await Task.sleep(for: delay)
			guard !Task.isCancelled, let self else { return }
			self.task = nil
			await retry()
		}
	}

	// The read went through, or a fresh connection: nothing pending, the first wait next.
	func reset() {
		backoff.reset()
		cancel()
	}

	func cancel() {
		task?.cancel()
		task = nil
	}
}
