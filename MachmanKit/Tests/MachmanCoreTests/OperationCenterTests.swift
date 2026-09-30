import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

// The long-running-operation registry behind host.operations / op.cancel /
// operationChanged: lifecycle, event emission, cancel semantics, terminal linger.
@MainActor
struct OperationCenterTests {

	@Test func lifecycleEmitsAndLists() async throws {
		let events = EventBus()
		let center = OperationCenter(events: events)
		var received: [VMEvent] = []
		let stream = events.stream()
		let collector = Task {
			for await event in stream {
				received.append(event)
				if received.count >= 3 { break }
			}
		}

		let id = center.begin(
			kind: OperationInfo.Kind.copyVM, vm: "Debian", label: "Copying…")
		#expect(center.list().map(\.id) == [id])
		center.update(id, fraction: 0.5, completedBytes: 50, totalBytes: 100)
		#expect(center.list().first?.fraction == 0.5)
		center.finish(id, state: OperationInfo.State.succeeded)
		let finished = center.list().first
		#expect(finished?.state == OperationInfo.State.succeeded)
		#expect(finished?.fraction == 1.0)   // success pins the bar full
		// Terminal state lingers for resync (reaped after ~10 s, not immediately).
		#expect(!center.list().isEmpty)

		await collector.value
		#expect(received.count == 3)
		for event in received {
			guard case .operationChanged(let op) = event else {
				Issue.record("expected operationChanged, got \(event)")
				continue
			}
			#expect(op.id == id)
		}
	}

	@Test func cancelSemantics() async throws {
		let events = EventBus()
		let center = OperationCenter(events: events)

		// No hook: refuse with invalidState.
		let fixed = center.begin(kind: "x", label: "uncancellable")
		#expect(throws: MachmanError.self) { try center.cancel(id: fixed) }

		// With a hook: cancel() pulls the trigger; the operation's own path finishes it.
		var pulled = false
		let id = center.begin(kind: "y", label: "cancellable", cancel: { pulled = true })
		try center.cancel(id: id)
		#expect(pulled)
		center.finish(id, state: OperationInfo.State.cancelled)
		#expect(center.list().first { $0.id == id }?.state == OperationInfo.State.cancelled)

		// Finished/unknown ids: notFound.
		#expect(throws: MachmanError.self) { try center.cancel(id: id) }
		#expect(throws: MachmanError.self) { try center.cancel(id: "op-ghost") }

		// finish() is idempotent: a late failure can't overwrite the terminal state.
		center.finish(id, state: OperationInfo.State.failed, message: "late")
		#expect(center.list().first { $0.id == id }?.state == OperationInfo.State.cancelled)
	}
}
