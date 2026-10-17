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
//  and the store retries with a backoff until a list lands (P13). One fetch is in flight at
//  a time (P8): what is asked meanwhile — events, actions' refreshes — is answered by the
//  fetch after it, so a burst costs two fetches, not one each, and an older reply can never
//  land over a newer list — nor over a state patched while it was out.
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
	// The fetch in flight (its id outlives a detach), the requests made so far, and how many
	// of them the last landed fetch answers: one started after a request answers it.
	private var fetch: Task<Void, Never>?
	private var fetchID = 0
	private(set) var asked = 0
	private var answered = 0
	// States patched while the fetch in flight was out: its list may have been read before
	// them, so they are laid over it, and the follow-up they asked for is the authority. A
	// list that put an older state back flipped the VM for a round trip, toasting each flip
	// (review F6).
	private var patchedDuringFetch: [String: VMState] = [:]

	public init(retryDelays: [Duration] = RetryBackoff.standardDelays) {
		backoff = RetryBackoff(delays: retryDelays)
	}

	// Wire the store to a (re)connection: subscribe first, then load, so no change between
	// the two is missed. The pump never waits on a fetch: events met meanwhile join the next.
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
				self.handle(event: event)
			}
		}
	}

	public func detach() {
		eventTask?.cancel()
		eventTask = nil
		retryTask?.cancel()
		retryTask = nil
		fetch?.cancel()
		fetch = nil
		fetchID += 1
		patchedDuringFetch = [:]
		api = nil
	}

	// Returns once a list fetched after this call landed (or failed to load).
	public func reload() async {
		asked += 1
		let mine = asked
		while answered < mine, api != nil {
			startFetch()
			await fetch?.value
		}
	}

	// An event's reload: it joins the fetch after the one in flight, or starts one now.
	public func requestReload() {
		asked += 1
		startFetch()
	}

	private func startFetch() {
		guard fetch == nil, let api else { return }
		fetchID += 1
		let id = fetchID
		let covers = asked
		patchedDuringFetch = [:]
		fetch = Task { [weak self] in
			await self?.fetchList(from: api, answering: covers)
			guard let self, self.fetchID == id else { return }
			self.fetch = nil
			if self.answered < self.asked { self.startFetch() }
		}
	}

	private func fetchList(from api: MachmanControlling, answering covers: Int) async {
		let list: [VMInfo]
		do {
			list = try await api.listVMs()
		} catch {
			// A fetch outlived by its connection reports nothing; the next one owns that.
			guard self.api === api, !(error is CancellationError) else { return }
			answered = max(answered, covers)   // answered with the problem; the retry goes on
			MachmanLogger.log(.passiveWarning, "couldn't refresh the VM list: \(error)")
			listProblem = String(describing: error)
			scheduleRetry()
			return
		}
		guard self.api === api else { return }
		answered = max(answered, covers)
		var landed = list
		for index in landed.indices {
			if let state = patchedDuringFetch[landed[index].name] { landed[index].state = state }
		}
		vms = landed
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

	// Capabilities are fetched once per connection; forms showing live figures (free disk
	// space) refresh explicitly through VMListViewModel.refreshFreeSpace (P44).
	public func refreshCapabilities() async {
		guard let api else { return }
		if let caps = try? await api.hostCapabilities() {
			capabilities = caps
		}
	}

	private func handle(event: VMEvent) {
		switch event {
		case .stateChanged(let name, let state):
			// The list in flight may predate this change: the fetch after it reads the state
			// again, and a patched row's state is laid over the list in flight meanwhile. A
			// VM no row holds yet was never seen in that state: its list stands (review F12).
			if fetch != nil { asked += 1 }
			if let index = vms.firstIndex(where: { $0.name == name }) {
				vms[index].state = state
				if fetch != nil { patchedDuringFetch[name] = state }
			}
		case .listChanged:
			requestReload()
		default:
			break
		}
	}
}
