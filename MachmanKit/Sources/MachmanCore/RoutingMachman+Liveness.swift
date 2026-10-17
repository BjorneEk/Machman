//
//  RoutingMachman+Liveness.swift
//  MachmanCore
//
//  Whether a vmhost is there and answering: its connection and what a dropped one means (E8),
//  the bounded probes, and the stall marks with their recovery watch (E20).
//

import Foundation
import MachmanAPI
import MachmanClient

extension RoutingMachman {
	func connectHost(identity: HostIdentity) async throws -> RemoteMachman {
		let hostID = identity.id
		return try await RemoteMachman(
			socketPath: identity.socketPath, clientName: "machman-agent-router",
			// Tight: spawnHost retries this in a loop and adoption runs it per socket while
			// the server parks requests — a vmhost that accepts but never answers hello must
			// fail fast, not add 30 s per attempt.
			helloDeadline: helloDeadline,
			onDisconnect: { [weak self] in
				Task { @MainActor [weak self] in
					self?.hostDisconnected(id: hostID)
				}
			})
	}

	// E8: a dropped connection is not a death — a spurious read or write failure used to tear
	// down a live run and delete a safe run's shadow under it. Only a confirmed exit ends the
	// run (the deathWatch's isTerminated stays authoritative); a live host is reconnected, or
	// listed as not responding until it answers again or exits.
	private func hostDisconnected(id: UUID) {
		guard let host = host(withID: id), host.reconnectTask == nil else { return }
		let clock = ContinuousClock()
		let exitBy = clock.now.advanced(by: hostExitGrace)
		host.reconnectTask = Task { [weak self] in
			while !Task.isCancelled {
				guard let settled = await self?.settleStep(id: id, pastGrace: clock.now >= exitBy),
					!settled else { return }
				let pause = clock.now < exitBy
					? Duration.milliseconds(50) : (self?.recoveryInterval ?? .seconds(2))
				try? await Task.sleep(for: pause)
			}
		}
	}

	// One look at a disconnected host; true once it is decided (gone or reconnected). An
	// orderly vmhost exit darkens its socket before it closes connections, so a live socket
	// means a dropped connection; a dark one with a live process is a host on its way out
	// (or wedged), which the grace lets go before it lists as not responding.
	private func settleStep(id: UUID, pastGrace: Bool) async -> Bool {
		guard let host = host(withID: id) else { return true }
		if hostExited(host) {
			hostGone(id: id)
			return true
		}
		if UDSListener.isLive(path: host.identity.socketPath),
			let client = try? await connectHost(identity: host.identity) {
			let answer: VMInfo?
			do {
				answer = try await client.vm(named: host.identity.name, deadline: hostProbeDeadline)
			} catch let error as MachmanError where error.code == .timeout {
				answer = nil
			} catch {
				await client.disconnect()
				return false
			}
			guard let host = self.host(withID: id) else {
				await client.disconnect()
				return true
			}
			reattach(host, client, answer: answer)
			return true
		}
		if pastGrace {
			markUnresponsive(host, reason: "lost its connection; the vmhost is still running")
		}
		return false
	}

	// Spawned hosts: the app. Adopted ones: the socket peer's pid (launchd reaps vmhosts, so
	// kill(pid, 0) is a sound check); without one, a dark socket.
	private func hostExited(_ host: HostedVM) -> Bool {
		if host.app?.isTerminated == true { return true }
		guard let pid = host.app?.processIdentifier ?? host.client.peerPID else {
			return !UDSListener.isLive(path: host.identity.socketPath)
		}
		return !isProcessAlive(pid)
	}

	private func reattach(_ host: HostedVM, _ client: RemoteMachman, answer: VMInfo?) {
		host.client = client
		host.reconnectTask = nil
		host.eventTask?.cancel()
		subscribeEvents(host)
		if let answer {
			host.lastAnswer = answer
			markResponsive(host)
		} else {
			markUnresponsive(host)
		}
		MachmanLogger.log(.passiveWarning,
			"reconnected to \(host.identity.name)'s vmhost after its connection dropped")
		registry.events.emit(.listChanged)
	}

	// MARK: - Stalled vmhosts (E20)

	enum ProbeResult {
		case answered(VMInfo)
		case stalled   // missed hostProbeDeadline
		case failed    // anything else: the host is going away, and hostGone follows
	}

	// One bounded vm.get to a host, recorded: an answer becomes its last answer and clears
	// a stall mark, a missed deadline sets one. A running answer also proves the host ran:
	// one adopted while it missed its deadline never sees a running event for that run.
	func probe(_ host: HostedVM) async -> ProbeResult {
		let result: ProbeResult
		do {
			result = .answered(try await host.client.vm(
				named: host.identity.name, deadline: hostProbeDeadline))
		} catch let error as MachmanError where error.code == .timeout {
			result = .stalled
		} catch {
			result = .failed
		}
		// Only for the host still serving: a probe that outlived its host changes nothing.
		guard host.identity.id == hosted[host.identity.name]?.identity.id else { return result }
		switch result {
		case .answered(let info):
			host.lastAnswer = info
			if info.state.isRunning { host.sawRun = true }
			markResponsive(host)
		case .stalled:
			markUnresponsive(host)
		case .failed:
			break
		}
		return result
	}

	// A spawned vmhost a start waits on (E64): asked like a list probe every recoveryInterval
	// while the start runs, and listed as not responding while it misses the answer deadline
	// — Force Stop and End Process end it. A vmhost going away ends the watch: the start
	// fails on its own.
	func watchStartingHost(_ host: HostedVM, name: String, flight: StartInFlight) {
		flight.watch?.cancel()
		flight.watch = Task { [weak self] in
			while !Task.isCancelled {
				guard let deadline = self?.hostProbeDeadline else { return }
				let stalled: Bool
				do {
					_ = try await host.client.vm(named: name, deadline: deadline)
					stalled = false
				} catch let error as MachmanError where error.code == .timeout {
					stalled = true
				} catch {
					return
				}
				guard !Task.isCancelled, let self else { return }
				if host.unresponsive != stalled {
					host.unresponsive = stalled
					MachmanLogger.log(.passiveWarning, stalled
						? "\(name)'s vmhost missed its \(deadline) answer deadline while starting "
							+ "— listing it as not responding"
						: "\(name)'s vmhost answers again")
					self.registry.events.emit(.listChanged)
				}
				try? await Task.sleep(for: self.recoveryInterval)
			}
		}
	}

	// Transitions only: each one logs, announces itself with listChanged (clients reload on
	// it — the only way a recovered VM's mark ever clears), and starts or ends the watcher.
	func markUnresponsive(_ host: HostedVM, reason: String? = nil) {
		guard !host.unresponsive else { return }
		host.unresponsive = true
		MachmanLogger.log(.passiveWarning,
			"\(host.identity.name)'s vmhost "
				+ (reason ?? "missed its \(hostProbeDeadline) answer deadline")
				+ " — listing it as not responding")
		startRecoveryWatch(host)
		registry.events.emit(.listChanged)
	}

	private func markResponsive(_ host: HostedVM) {
		guard host.unresponsive else { return }
		host.unresponsive = false
		host.recoveryTask?.cancel()
		host.recoveryTask = nil
		MachmanLogger.log(.log, "\(host.identity.name)'s vmhost answers again")
		registry.events.emit(.listChanged)
	}

	// Asks a marked host again every recoveryInterval until it answers (the answer clears
	// the mark and ends the watch) or it is gone. Keyed by identity.id, like discovery.
	private func startRecoveryWatch(_ host: HostedVM) {
		host.recoveryTask?.cancel()
		let id = host.identity.id
		host.recoveryTask = Task { [weak self] in
			while !Task.isCancelled {
				guard let interval = self?.recoveryInterval else { return }
				try? await Task.sleep(for: interval)
				guard !Task.isCancelled, let self, let host = self.host(withID: id),
					host.unresponsive else { return }
				_ = await self.probe(host)
			}
		}
	}
}
