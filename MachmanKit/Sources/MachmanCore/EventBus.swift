//
//  EventBus.swift
//  Machman
//
//  Fan-out for engine events. Every stream() call gets an independent AsyncStream fed by every
//  emit() from subscription time on — the same shape a daemon needs to feed one event feed per
//  client connection, used in-process for now.
//

import Foundation
import MachmanAPI

@MainActor
final class EventBus {
	private var continuations: [UUID: AsyncStream<VMEvent>.Continuation] = [:]

	func stream() -> AsyncStream<VMEvent> {
		AsyncStream { continuation in
			let id = UUID()
			self.continuations[id] = continuation
			continuation.onTermination = { _ in
				Task { @MainActor [weak self] in
					self?.continuations[id] = nil
				}
			}
		}
	}

	func emit(_ event: VMEvent) {
		// The console is the one guaranteed sink for log lines; print them exactly once, here.
		if case .log(_, _, let message) = event {
			print(message)
		}
		for continuation in continuations.values {
			continuation.yield(event)
		}
	}
}
