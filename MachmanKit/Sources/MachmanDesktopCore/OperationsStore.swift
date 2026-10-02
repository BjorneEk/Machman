//
//  OperationsStore.swift
//  MachmanDesktopCore
//
//  App-scoped store of long-running work: the daemon's OperationInfo registry mirror and the
//  per-VM macOS install phases. Owns its own event stream (installPhaseChanged +
//  operationChanged); events have no replay, so each (re)attach pulls host.operations once
//  and lets the stream keep it fresh; a pull that fails is retried with a backoff (P13).
//  Finished entries linger briefly (the progress card shows the outcome), then prune —
//  whether a terminal event or a resync brought them — and a pruned one never comes back
//  on a later resync, though the daemon keeps listing it for a while (P24). Each finished
//  operation also lands in the activity list once (PR5), which this store owns so it
//  outlives reconnects like the store itself.
//

import Foundation
import MachmanAPI

@MainActor
public final class OperationsStore: ObservableObject {
	@Published public private(set) var operations: [OperationInfo] = []
	@Published public private(set) var installPhases: [String: InstallPhase] = [:]
	private var api: MachmanControlling?
	private var eventTask: Task<Void, Never>?
	private var retryTask: Task<Void, Never>?
	private var backoff: RetryBackoff
	private let linger: Duration
	// Finished operations already pruned here; host.operations may still list them.
	private var forgotten: Set<String> = []
	// macOS VMs whose install phase is being fetched (dedupes re-triggered primes).
	private var phasePrimesInFlight: Set<String> = []
	// The activity list, and the finished operations already in it (event or resync).
	public let activity: ActivityLog
	private var recorded: Set<String> = []

	// `activity` nil = an in-memory list. Resolved in the body: a default argument is
	// evaluated outside the main actor, where ActivityLog's init is out of reach.
	public init(
		retryDelays: [Duration] = RetryBackoff.standardDelays, linger: Duration = .seconds(5),
		activity: ActivityLog? = nil
	) {
		backoff = RetryBackoff(delays: retryDelays)
		self.linger = linger
		self.activity = activity ?? ActivityLog()
	}

	public func attach(api: MachmanControlling) {
		detach()
		self.api = api
		backoff.reset()
		eventTask = Task { [weak self] in
			let stream = await api.events()
			await self?.resync()
			for await event in stream {
				guard let self else { return }
				self.handle(event: event)
			}
		}
	}

	public func detach() {
		eventTask?.cancel()
		eventTask = nil
		retryTask?.cancel()
		retryTask = nil
		api = nil
		phasePrimesInFlight.removeAll()
	}

	// A finished card's ✕: gone here and now, and never resynced back. Local only — there
	// is nothing on the daemon to cancel (F2).
	public func dismiss(id: String) {
		guard operations.contains(where: { $0.id == id && $0.isFinished }) else { return }
		operations.removeAll { $0.id == id }
		forgotten.insert(id)
	}

	// Prime phases for VMs the daemon reports mid-install: only a live install session
	// serves real progress; every other macInstallState derives its phase client-side
	// (VMListViewModel.installPhase(for:)) without a fetch — so no per-VM N+1 on reload.
	public func primeInstallPhases(for vms: [VMInfo]) {
		guard let api else { return }
		for vm in vms where vm.boot.macInstallState?.kind == .installing
			&& installPhases[vm.name] == nil && !phasePrimesInFlight.contains(vm.name) {
			phasePrimesInFlight.insert(vm.name)
			let name = vm.name
			Task { [weak self] in
				guard let self else { return }
				// Never clobber a phase an event delivered while the fetch was in flight.
				if let phase = try? await api.macInstallPhase(vm: name),
					self.installPhases[name] == nil {
					self.installPhases[name] = phase
				}
				self.phasePrimesInFlight.remove(name)
			}
		}
	}

	private func resync() async {
		guard let api else { return }
		let ops: [OperationInfo]
		do {
			ops = try await api.operations()
		} catch {
			guard self.api === api, !(error is CancellationError) else { return }
			MachmanLogger.log(.passiveWarning, "couldn't refresh operations: \(error)")
			scheduleRetry()
			return
		}
		guard self.api === api else { return }
		// Only ids the daemon still lists can come back, so that is all these two keep.
		forgotten.formIntersection(ops.map(\.id))
		recorded.formIntersection(ops.map(\.id))
		operations = ops.filter { !forgotten.contains($0.id) }
		for op in operations where op.isFinished {
			recordOutcome(op)
			schedulePrune(op.id)
		}
		backoff.reset()
	}

	// Once per operation. The list may already hold it: a relaunch's first resync lists
	// what the last session recorded.
	private func recordOutcome(_ op: OperationInfo) {
		guard recorded.insert(op.id).inserted,
			!activity.contains(key: ActivityEntry.operationKey(op.id)) else { return }
		activity.record(.operation(op, at: Date()))
	}

	private func schedulePrune(_ id: String) {
		let linger = self.linger
		Task { [weak self] in
			try? await Task.sleep(for: linger)
			guard let self else { return }
			self.operations.removeAll { $0.id == id && $0.isFinished }
			self.forgotten.insert(id)
		}
	}

	// Silent: progress cards are passive, and the next event or retry fills them in.
	private func scheduleRetry() {
		guard retryTask == nil else { return }
		let delay = backoff.next()
		retryTask = Task { [weak self] in
			try? await Task.sleep(for: delay)
			guard !Task.isCancelled, let self else { return }
			self.retryTask = nil
			await self.resync()
		}
	}

	private func handle(event: VMEvent) {
		switch event {
		case .installPhaseChanged(let name, let phase):
			installPhases[name] = phase
		case .operationChanged(let op):
			if let i = operations.firstIndex(where: { $0.id == op.id }) {
				operations[i] = op
			} else {
				operations.append(op)
			}
			// Terminal states linger briefly (the card shows the outcome) then prune.
			if op.isFinished {
				recordOutcome(op)
				schedulePrune(op.id)
			}
		default:
			break
		}
	}
}
