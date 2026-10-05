//
//  TGEvents.swift
//  MachmanLabTests
//
//  The agent's event stream, recorded: a test marks a point, acts, and reads what followed
//  (copy progress, operation cards, warnings) or waits for one event. Events have no replay,
//  so the recorder subscribes before the act it watches.
//

import Foundation
import MachmanAPI
import MachmanClient

final class TGEvents: @unchecked Sendable {
	private let lock = NSLock()
	private var events: [VMEvent] = []
	private var task: Task<Void, Never>?

	private init() {}

	/// Subscribed when this returns: every later event is recorded.
	static func record(_ api: RemoteMachman) async -> TGEvents {
		let recorder = TGEvents()
		let stream = await api.events()
		recorder.task = Task { [recorder] in
			for await event in stream { recorder.lock.withLock { recorder.events.append(event) } }
		}
		return recorder
	}

	func stop() { task?.cancel() }

	/// The index the next event gets: what `since` and `waitFor` count from.
	func mark() -> Int { lock.withLock { events.count } }

	func since(_ mark: Int = 0) -> [VMEvent] {
		lock.withLock { Array(events.dropFirst(mark)) }
	}

	@discardableResult
	func waitFor(
		after mark: Int = 0, timeout: Duration = .seconds(30), _ match: (VMEvent) -> Bool
	) async throws -> VMEvent {
		let deadline = ContinuousClock.now + timeout
		while true {
			if let hit = since(mark).first(where: match) { return hit }
			if ContinuousClock.now >= deadline {
				throw LabError.specInvalid("no matching event in \(timeout)")
			}
			try await Task.sleep(for: .milliseconds(50))
		}
	}

	struct Progress: Equatable {
		var copied: UInt64
		var total: UInt64
	}

	func copyProgress(vm: String, after mark: Int = 0) -> [Progress] {
		since(mark).compactMap {
			guard case .copyProgress(vm, let copied, let total) = $0 else { return nil }
			return Progress(copied: copied, total: total)
		}
	}

	func operations(kind: String, vm: String, after mark: Int = 0) -> [OperationInfo] {
		since(mark).compactMap {
			guard case .operationChanged(let op) = $0, op.kind == kind, op.vm == vm else {
				return nil
			}
			return op
		}
	}

	func warnings(vm: String, after mark: Int = 0) -> [String] {
		since(mark).compactMap {
			guard case .log(vm, .warning, let message) = $0 else { return nil }
			return message
		}
	}

	/// Waits for the first copy-progress event of `vm` that is mid-copy.
	@discardableResult
	func waitForMidCopy(vm: String, after mark: Int = 0, timeout: Duration = .seconds(30))
		async throws -> Progress {
		let event = try await waitFor(after: mark, timeout: timeout) {
			guard case .copyProgress(vm, let copied, let total) = $0 else { return false }
			return copied < total
		}
		guard case .copyProgress(_, let copied, let total) = event else { fatalError() }
		return Progress(copied: copied, total: total)
	}
}
