//
//  VMStore.swift
//  MachmanDesktopCore
//
//  App-scoped source of truth for the VM list and host capabilities. Owns its own event
//  subscription (the transport fans events out per subscriber): stateChanged patches the row
//  in place, listChanged reloads. Lives OUTSIDE the per-connection view model — DaemonConnection
//  re-attaches it to each new RemoteMachman, so list state survives daemon reconnects.
//  Consumers needing to react AFTER a refresh lands sink $vms (it emits the incoming value).
//

import Foundation
import MachmanAPI

@MainActor
public final class VMStore: ObservableObject {
	@Published public private(set) var vms: [VMInfo] = []
	@Published public private(set) var capabilities: HostCapabilities?
	public private(set) var api: MachmanControlling?
	private var eventTask: Task<Void, Never>?

	public init() {}

	// Wire the store to a (re)connection: subscribe first, then load, so no change between
	// the two is missed. The pump is serial — a reload finishes before the next event.
	public func attach(api: MachmanControlling) {
		detach()
		self.api = api
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
		api = nil
	}

	public func reload() async {
		guard let api else { return }
		if let list = try? await api.listVMs() {
			vms = list
		}
		if capabilities == nil {
			capabilities = try? await api.hostCapabilities()
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
