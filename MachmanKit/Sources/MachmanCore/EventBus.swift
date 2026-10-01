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

	// The streams keep AsyncStream's unbounded buffer on purpose: every subscriber drains on
	// the main actor without blocking — the server's per-client pump only enqueues a write,
	// the router re-emits, the vmhost's lifecycle watcher and the agent menu only read state.
	// A client that stops reading backs up in its connection's write queue instead, which is
	// bounded in time and bytes (E17, UDSConnection).
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
		// The logger is the one guaranteed sink for log lines; route them exactly once, here.
		if case .log(let vm, let level, let message) = event {
			MachmanLogger.log(level.logType, "\(vm.map { "(\($0)) " } ?? "")\(message)")
		}
		for continuation in continuations.values {
			continuation.yield(event)
		}
	}
}
