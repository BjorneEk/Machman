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
			for notice in self.standingNotices {
				continuation.yield(notice)
			}
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
			for notice in self.standingNotices {
				continuation.yield(EventLine(event: notice, line: nil))
			}
			continuation.onTermination = { _ in
				Task { @MainActor [weak self] in
					self?.lineContinuations[id] = nil
				}
			}
		}
	}

	// Standing notices (D38): what stays true while this process runs — a VM folder whose
	// settings couldn't be read — reaches every subscriber, the ones that subscribe later
	// included (the registry scans before any client connects). One per key; a new stream
	// gets them first, in key order.
	private var notices: [String: VMEvent] = [:]

	private var standingNotices: [VMEvent] {
		notices.keys.sorted().compactMap { notices[$0] }
	}

	func post(notice event: VMEvent, key: String) {
		notices[key] = event
		emit(event)
	}

	// Where a log event is written: the unified log. A seam for tests.
	var logSink: (MachmanLogType, String) -> Void = { MachmanLogger.log($0, $1) }

	func emit(_ event: VMEvent) {
		emit(event, line: nil)
	}

	// `line`: the notification a vmhost sent this event in, passed on to clients as is.
	// `logs`: the logger is the one guaranteed sink for log lines, written once, by the bus of
	// the process the line comes from. A vmhost's event passed on here was written in its
	// vmhost: the router passes it on with `logs: false` (E69).
	func emit(_ event: VMEvent, line: Data?, logs: Bool = true) {
		if logs, case .log(let vm, let level, let message) = event {
			logSink(level.logType, "\(vm.map { "(\($0)) " } ?? "")\(message)")
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
