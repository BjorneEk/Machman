//
//  OperationCenter.swift
//  MachmanCore
//
//  The registry behind host.operations / op.cancel / operationChanged (wire 1.0.4). Every
//  long-running engine operation (copies, disk imports/promotes, shadow builds, kernel
//  imports, Rosetta installs) registers here; each change broadcasts an operationChanged
//  event, and terminal states linger briefly so clients can resync via host.operations
//  after a reconnect (events have no replay). Both the daemon and each vmhost run one;
//  RoutingMachman merges the lists and fans op.cancel out.
//
//  Progress callers are expected to be pre-throttled (the copy paths already run through
//  ProgressThrottle), so update() emits unconditionally.
//

import Foundation
import MachmanAPI

// A tiny cross-queue cancellation flag for @Sendable isCancelled closures (VMCopier /
// DiskImport run detached).
final class CancelFlag: @unchecked Sendable {
	private let lock = NSLock()
	private var flag = false

	func set() {
		lock.lock()
		flag = true
		lock.unlock()
	}

	func get() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		return flag
	}
}

@MainActor
final class OperationCenter {
	private let events: EventBus
	private var operations: [String: OperationInfo] = [:]
	private var cancelHooks: [String: () -> Void] = [:]
	private var reapTasks: [String: Task<Void, Never>] = [:]
	// How long a finished operation stays listable for reconnect resync.
	private let terminalLinger: Duration = .seconds(10)

	init(events: EventBus) {
		self.events = events
	}

	// Registers a running operation and broadcasts it. The cancel hook (optional — some
	// operations genuinely can't stop) must drive the operation to a terminal state via its
	// own failure path; cancel() only pulls the trigger. Whether there is one rides along as
	// `cancellable`, so clients don't offer a Cancel that cancel() would refuse (F7).
	func begin(
		kind: String, vm: String? = nil, label: String, cancel: (() -> Void)? = nil
	) -> String {
		let id = "op-" + UUID().uuidString.lowercased()
		let op = OperationInfo(
			id: id, kind: kind, vm: vm, label: label, startedAt: Date(),
			cancellable: cancel != nil)
		operations[id] = op
		if let cancel { cancelHooks[id] = cancel }
		events.emit(.operationChanged(op: op))
		return id
	}

	func update(
		_ id: String, fraction: Double? = nil, completedBytes: Int64? = nil,
		totalBytes: Int64? = nil, label: String? = nil
	) {
		guard var op = operations[id], op.state == OperationInfo.State.running else { return }
		if let fraction { op.fraction = fraction }
		if let completedBytes { op.completedBytes = completedBytes }
		if let totalBytes { op.totalBytes = totalBytes }
		if let label { op.label = label }
		operations[id] = op
		events.emit(.operationChanged(op: op))
	}

	func finish(_ id: String, state: String, message: String? = nil) {
		guard var op = operations[id], op.state == OperationInfo.State.running else { return }
		op.state = state
		op.message = message
		if state == OperationInfo.State.succeeded { op.fraction = 1.0 }
		operations[id] = op
		cancelHooks[id] = nil
		events.emit(.operationChanged(op: op))
		reapTasks[id] = Task { [weak self, terminalLinger] in
			try? await Task.sleep(for: terminalLinger)
			self?.operations[id] = nil
			self?.reapTasks[id] = nil
		}
	}

	func cancel(id: String) throws {
		guard let op = operations[id], op.state == OperationInfo.State.running else {
			throw MachmanError(code: .notFound, message: "That operation already ended")
		}
		guard let hook = cancelHooks[id] else {
			throw MachmanError(
				code: .invalidState, message: "This operation can’t be canceled")
		}
		hook()
	}

	func list() -> [OperationInfo] {
		operations.values.sorted { $0.startedAt < $1.startedAt }
	}
}
