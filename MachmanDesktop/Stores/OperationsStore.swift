//
//  OperationsStore.swift
//  MachmanDesktop
//
//  App-scoped store of long-running work: the daemon's OperationInfo registry mirror and the
//  per-VM macOS install phases. Owns its own event stream (installPhaseChanged +
//  operationChanged); events have no replay, so each (re)attach pulls host.operations once
//  and lets the stream keep it fresh. The progress-card UI (S7) consumes `operations` and
//  owns dismissal/pruning of finished entries; until then they just accumulate here.
//

import Foundation
import MachmanAPI

@MainActor
final class OperationsStore: ObservableObject {
	@Published private(set) var operations: [OperationInfo] = []
	@Published private(set) var installPhases: [String: InstallPhase] = [:]
	private var api: MachmanControlling?
	private var eventTask: Task<Void, Never>?
	// macOS VMs whose install phase is being fetched (dedupes re-triggered primes).
	private var phasePrimesInFlight: Set<String> = []

	func attach(api: MachmanControlling) {
		detach()
		self.api = api
		eventTask = Task { [weak self] in
			let stream = await api.events()
			await self?.resync()
			for await event in stream {
				guard let self else { return }
				self.handle(event: event)
			}
		}
	}

	func detach() {
		eventTask?.cancel()
		eventTask = nil
		api = nil
		phasePrimesInFlight.removeAll()
	}

	// Prime phases for VMs the daemon reports mid-install: only a live install session
	// serves real progress; every other macInstallState derives its phase client-side
	// (VMListViewModel.installPhase(for:)) without a fetch — so no per-VM N+1 on reload.
	func primeInstallPhases(for vms: [VMInfo]) {
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
		if let ops = try? await api.operations() {
			operations = ops
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
				let id = op.id
				Task { [weak self] in
					try? await Task.sleep(for: .seconds(5))
					self?.operations.removeAll { $0.id == id && $0.isFinished }
				}
			}
		default:
			break
		}
	}
}
