//
//  TFEvents.swift
//  MachmanLabTests
//
//  Records every event one connection's stream delivers. A stream on a dead connection never
//  ends (r3-ta's finding), so nothing here awaits the stream itself: waits poll the record
//  with a deadline, and stop() cancels the pump.
//

import Foundation
import MachmanAPI

final class TFEvents: @unchecked Sendable {
	private let lock = NSLock()
	private var events: [VMEvent] = []
	private var pump: Task<Void, Never>?

	/// Subscribes before returning, so an event sent after `init` lands in the record.
	init(api: MachmanControlling) async {
		let stream = await api.events()
		pump = Task { [weak self] in
			for await event in stream {
				guard let self else { return }
				self.lock.withLock { self.events.append(event) }
			}
		}
	}

	deinit { pump?.cancel() }

	var all: [VMEvent] { lock.withLock { events } }

	/// The messages of the .log events for `vm` (nil vm = engine-wide) at `level`.
	func logs(vm: String?, level: LogLevel) -> [String] {
		all.compactMap {
			if case .log(let v, let l, let message) = $0, v == vm, l == level { return message }
			return nil
		}
	}

	func count(where match: (VMEvent) -> Bool) -> Int { all.filter(match).count }

	/// The first recorded event matching `match`, waited for up to `timeout`.
	@discardableResult
	func waitFor(
		_ what: String, timeout: Duration, where match: @escaping (VMEvent) -> Bool
	) async throws -> VMEvent {
		let deadline = ContinuousClock.now + timeout
		while true {
			if let hit = all.first(where: match) { return hit }
			if ContinuousClock.now >= deadline { throw TFError.timeout("event: \(what)") }
			try await Task.sleep(for: .milliseconds(100))
		}
	}

	func stop() { pump?.cancel() }
}
