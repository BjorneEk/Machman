//
//  RoutingMachman+Adoption.swift
//  MachmanCore
//
//  Adopting a vmhost this daemon did not spawn — at startup, from a probe, on demand: one
//  adoption per name, its bounded first ask, and the retry timer for a host that did not answer
//  (E61).
//

import Foundation
import MachmanAPI
import MachmanClient

extension RoutingMachman {
	// The vmhost serving `name`, adopting one this daemon has not met yet: a launch-agent
	// start, a socket that appeared after startup adoption ran, a host that missed hello
	// then. Concurrent callers share one adoption.
	@discardableResult
	func adoptLiveHost(_ name: String) async throws -> HostedVM {
		if let host = hosted[name] { return host }
		if let inFlight = adoptions[name] { return try await inFlight.value }
		let socketPath = hostSocketPath(for: name)
		let adoption = Task { try await self.connectAndAdopt(name: name, socketPath: socketPath) }
		adoptions[name] = adoption
		defer { adoptions[name] = nil }
		do {
			let host = try await adoption.value
			unadoptable.remove(name)
			return host
		} catch {
			// Clients list the VM again once it can't be adopted (E53): it lists Not responding
			// from now on, which a client that listed it before (the agent menu, while startup
			// adoption ran) would never learn. A repeat failure inserts nothing, so no loop.
			// From then on its timer asks it again (E61).
			if UDSListener.isLive(path: socketPath), unadoptable.insert(name).inserted {
				registry.events.emit(.listChanged)
				retryAdoption(of: name)
			}
			throw error
		}
	}

	// Adopts each name's vmhost at once, each bounded by the hello and answer deadlines, so a
	// busy host costs its own wait and never the next one's (E43). Main-actor Tasks that
	// suspend inside the RPC, like the list probes.
	func adoptLiveHosts(_ names: [String]) async -> [String: Result<HostedVM, Error>] {
		let attempts = names.map { name in
			(name, Task { () -> Result<HostedVM, Error> in
				do {
					return .success(try await self.adoptLiveHost(name))
				} catch {
					return .failure(error)
				}
			})
		}
		var results: [String: Result<HostedVM, Error>] = [:]
		for (name, attempt) in attempts {
			results[name] = await attempt.value
		}
		return results
	}

	// Fire-and-forget adoption for the read paths; a no-op while one is in flight, and for a
	// name that could not be adopted (E61): every list asked that one again, and each connect
	// to a vmhost that never accepts stays in its accept queue for good. Its timer asks it.
	func scheduleAdoption(_ name: String) {
		guard adoptions[name] == nil, !unadoptable.contains(name) else { return }
		Task { _ = try? await self.adoptLiveHost(name) }
	}

	// An unadoptable name's adoption, tried again every adoptionRetryInterval until it is
	// adopted, or until its socket is dark: then clients list the VM again, stopped (nothing
	// watched that vmhost's exit). One timer per name.
	private func retryAdoption(of name: String) {
		guard adoptionRetries[name] == nil else { return }
		adoptionRetries[name] = Task { [weak self] in
			while let interval = self?.adoptionRetryInterval {
				try? await Task.sleep(for: interval)
				guard let self, !Task.isCancelled, self.unadoptable.contains(name) else { break }
				guard UDSListener.isLive(path: self.hostSocketPath(for: name)) else {
					self.unadoptable.remove(name)
					self.registry.events.emit(.listChanged)
					break
				}
				_ = try? await self.adoptLiveHost(name)
			}
			self?.adoptionRetries[name] = nil
		}
	}

	// The one adoption path — startup, probe-adopt and on demand: connect, ask the host once
	// (bounded; its reply is its first last answer), adopt, and re-attach the safe run it
	// may be serving.
	func connectAndAdopt(name: String, socketPath: String) async throws -> HostedVM {
		var identity = HostIdentity(id: UUID(), name: name, socketPath: socketPath)
		adoptionAttempts += 1
		let client = try await connectHost(identity: identity)
		// E11: a vmhost that says which folder it serves is this VM's only when that is the
		// VM's folder. One serving a folder under another name is a saved run on its
		// original's socket (E27), adopted as what it serves; any other is an orphan, never
		// adopted as this VM — its saves would land in this VM's folder.
		if let served = client.hello.host, !served.shadow, let folder = served.vmDir,
			!isSameFile(folder, libraryDir() + "/" + name) {
			guard served.vm != name, registry.vm(named: served.vm) != nil,
				isSameFile(folder, libraryDir() + "/" + served.vm) else {
				await client.disconnect()
				noteOrphan(served, at: socketPath)
				throw MachmanError(
					code: .invalidState,
					message: "Another VM’s process answers on \(name)’s socket")
			}
			identity.name = served.vm
		}
		var reply: VMInfo?
		do {
			reply = try await client.vm(named: identity.name, deadline: hostProbeDeadline)
		} catch let error as MachmanError where error.code == .notFound {
			// E27: the host serves another VM — a vmhost from before the socket followed
			// Save as New VM still answers on its original's path. Key it by what it
			// serves; never adopt a host as a VM it does not run.
			let served = (try? await client.listVMs(deadline: hostProbeDeadline)) ?? []
			guard served.count == 1, let actual = served.first, actual.name != name,
				registry.vm(named: actual.name) != nil else {
				await client.disconnect()
				throw MachmanError(
					code: .invalidState,
					message: "Another VM’s process answers on \(name)’s socket")
			}
			identity.name = actual.name
			reply = actual
		} catch {
			reply = nil   // a stall (E20): adopted, its first answer still to come
		}
		// The host's reply is the MAC the guest is actually using — it can differ from the
		// daemon's stale view (safe-save promotions rewrite it mid-run).
		identity.macInUse = reply?.macAddress
			?? registry.vm(named: identity.name)?.config.macAddress
		if let existing = hosted[identity.name] {
			// Another path got there during the awaits: never two hosts for one name. The
			// dropped client's disconnect finds no host with its id.
			await client.disconnect()
			return existing
		}
		let host = adopt(identity: identity, client: client)
		host.lastAnswer = reply
		host.sawRun = reply?.state.isRunning ?? false
		reattachSafeRun(host)
		return host
	}

	@discardableResult
	func adopt(identity: HostIdentity, client: RemoteMachman) -> HostedVM {
		let host = HostedVM(identity: identity, client: client, app: nil, deathWatch: nil)
		hosted[identity.name] = host
		subscribeEvents(host)
		if isOutdated(host) {
			MachmanLogger.log(.passiveWarning,
				"\(identity.name)'s vmhost runs \(host.version), older than this daemon's "
					+ "\(daemonVersion) — its settings are locked until it restarts")
		}
		// Adopted hosts are already running and may never emit another stateChanged —
		// this is how discovery (daemon memory) survives a daemon restart mid-run.
		startSSHDiscovery(host)
		registry.events.emit(.listChanged)
		return host
	}
}
