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
	// The server's subscribers: each event with the line a vmhost sent it in, if it came
	// from one (A10).
	private var lineContinuations: [UUID: AsyncStream<EventLine>.Continuation] = [:]

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

	func lineStream() -> AsyncStream<EventLine> {
		AsyncStream { continuation in
			let id = UUID()
			self.lineContinuations[id] = continuation
			continuation.onTermination = { _ in
				Task { @MainActor [weak self] in
					self?.lineContinuations[id] = nil
				}
			}
		}
	}

	func emit(_ event: VMEvent) {
		emit(event, line: nil)
	}

	// `line`: the notification a vmhost sent this event in, passed on to clients as is.
	func emit(_ event: VMEvent, line: Data?) {
		// The logger is the one guaranteed sink for log lines; route them exactly once, here.
		if case .log(let vm, let level, let message) = event {
			MachmanLogger.log(level.logType, "\(vm.map { "(\($0)) " } ?? "")\(message)")
		}
		for continuation in continuations.values {
			continuation.yield(event)
		}
		let forwarded = EventLine(event: event, line: line)
		for continuation in lineContinuations.values {
			continuation.yield(forwarded)
		}
	}
}

// What the server pumps to a subscribed client (A10): an engine's event bus, each vmhost
// event with its own line. Any other MachmanControlling is served from events(), encoded.
@MainActor
protocol EventLineSource: AnyObject {
	func eventLines() -> AsyncStream<EventLine>
}
