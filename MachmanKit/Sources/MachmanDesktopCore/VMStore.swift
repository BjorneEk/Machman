//
//  VMStore.swift
//  MachmanDesktopCore
//
//  App-scoped source of truth for the VM list and host capabilities. Owns its own event
//  subscription (the transport fans events out per subscriber): stateChanged patches the row
//  in place, listChanged reloads. Lives OUTSIDE the per-connection view model — DaemonConnection
//  re-attaches it to each new RemoteMachman, so list state survives daemon reconnects.
//  Consumers needing to react AFTER a refresh lands sink $vms (it emits the incoming value).
//  A list that fails to load is never silent: listProblem says so (the view model shows it)
//  and the store retries with a backoff until a list lands (P13).
//

import Foundation
import MachmanAPI

@MainActor
public final class VMStore: ObservableObject {
	@Published public private(set) var vms: [VMInfo] = []
	@Published public private(set) var capabilities: HostCapabilities?
	// Why the last list refresh failed; nil once a list lands. The list shown is the last
	// good one.
	@Published public private(set) var listProblem: String?
	public private(set) var api: MachmanControlling?
	private var eventTask: Task<Void, Never>?
	private var retryTask: Task<Void, Never>?
	private var backoff: RetryBackoff

	public init(retryDelays: [Duration] = RetryBackoff.standardDelays) {
		backoff = RetryBackoff(delays: retryDelays)
	}

	// Wire the store to a (re)connection: subscribe first, then load, so no change between
	// the two is missed. The pump is serial — a reload finishes before the next event.
	public func attach(api: MachmanControlling) {
		detach()
		self.api = api
		listProblem = nil
		backoff.reset()
		eventTask = Task { [weak self] in
			let stream = await api.events()
			await self?.reload()
			for await event in stream {
				guard let self else { return }
				await self.handle(event: event)
			}
		}
	}

	public func detach() {
		eventTask?.cancel()
		eventTask = nil
		retryTask?.cancel()
		retryTask = nil
		api = nil
	}

	public func reload() async {
		guard let api else { return }
		let list: [VMInfo]
		do {
			list = try await api.listVMs()
		} catch {
			// A reload outlived by its connection reports nothing; the next one owns that.
			guard self.api === api, !(error is CancellationError) else { return }
			MachmanLogger.log(.passiveWarning, "couldn't refresh the VM list: \(error)")
			listProblem = String(describing: error)
			scheduleRetry()
			return
		}
		guard self.api === api else { return }
		vms = list
		listProblem = nil
		if capabilities == nil, let caps = try? await api.hostCapabilities(),
			self.api === api {
			capabilities = caps
		}
		guard self.api === api else { return }
		if capabilities == nil {
			scheduleRetry()   // the sheets' limits are missing; the list itself is fine
		} else {
			backoff.reset()
			retryTask?.cancel()
			retryTask = nil
		}
	}

	// One pending retry at a time; it clears itself before reloading, so a reload that
	// fails again schedules the next one.
	private func scheduleRetry() {
		guard retryTask == nil else { return }
		let delay = backoff.next()
		retryTask = Task { [weak self] in
			try? await Task.sleep(for: delay)
			guard !Task.isCancelled, let self else { return }
			self.retryTask = nil
			await self.reload()
		}
	}

	// Capabilities are fetched once per connection; sheets showing live figures (free disk
	// space) refresh explicitly so the number isn't sessions old.
	public func refreshCapabilities() async {
		guard let api else { return }
		if let caps = try? await api.hostCapabilities() {
			capabilities = caps
		}
	}

	private func handle(event: VMEvent) async {
		switch event {
		case .stateChanged(let name, let state):
			if let index = vms.firstIndex(where: { $0.name == name }) {
				vms[index].state = state
			}
		case .listChanged:
			await reload()
		default:
			break
		}
	}
}
