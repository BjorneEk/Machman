//
//  RoutingMachman+Supervisor.swift
//  MachmanCore
//
//  The host table and a host's way out: the table's reads, the waits for a host that is leaving
//  (E12, E52), stopping hosted VMs (the quit path's stop-all, the bounded force stop), ending a
//  vmhost that doesn't answer (C9), and hostGone.
//

import Foundation
import MachmanAPI
import MachmanClient

extension RoutingMachman {
	var hostedNames: [String] { Array(hosted.keys) }

	// Test seam: lets tests mutate an adopted host's identity (what the sweep's re-attach
	// path does) without fabricating run roots.
	func hostForTesting(_ name: String) -> HostedVM? { hosted[name] }

	// The VMs that run now, by name: a hosted one whose VM the host last reported running
	// (starting and stopping count), that stopped answering, or that has not answered yet (an
	// adoption whose first ask stalled — unknown, never stopped), and every start in flight.
	// An idle host, or one exiting after its run, has answered: it holds nothing up and quits
	// with the session.
	public var runningVMNames: [String] {
		let hostedRunning = hosted.values
			.filter { $0.unresponsive || ($0.lastState?.isRunning ?? true) }
			.map(\.identity.name)
		return Set(hostedRunning).union(pendingStarts).sorted()
	}

	// What holds a log out, restart or shut down (V10): every VM runningVMNames counts, and
	// whether its own vmhost cancels in front and says what to do. Only a vmhost running its
	// VM and answering does; a start in flight (its vmhost not there yet, or idle until the
	// start arrives), a host that stopped answering and one that never answered leave it to
	// the agent — as does work the agent runs itself on a VM that runs nothing (C13). A copy a
	// vmhost runs for the agent (an import it drains into its stopped VM) holds it too: that
	// vmhost cancels the log out and says so (E46), and the agent must stay with it (V15). One
	// entry per VM.
	public var sessionHolders: [SessionHolder] {
		let starting = pendingStarts
		var holders: [String: SessionHolder] = [:]
		for name in starting {
			holders[name] = SessionHolder(
				vm: name, activity: "is still starting", promptsItself: false)
		}
		for host in hosted.values where holders[host.identity.name] == nil {
			let name = host.identity.name
			if host.unresponsive || host.lastState == nil {
				holders[name] = SessionHolder(
					vm: name, activity: "is not responding", promptsItself: false)
			} else if host.lastState?.isRunning == true {
				holders[name] = SessionHolder(
					vm: name, activity: "is still running", promptsItself: true)
			}
		}
		for (name, kind) in claims.inDaemon where holders[name] == nil {
			holders[name] = SessionHolder(
				vm: name, activity: kind.activity, promptsItself: false, isAgentWork: true)
		}
		for (name, kind) in claims.proxied where holders[name] == nil {
			holders[name] = SessionHolder(vm: name, activity: kind.activity, promptsItself: true)
		}
		for vm in registry.list() where holders[vm.name] == nil && registry.isInstalling(vm) {
			holders[vm.name] = SessionHolder(
				vm: vm.name, activity: "is installing macOS", promptsItself: false,
				isAgentWork: true)
		}
		return holders.values.sorted { $0.vm < $1.vm }
	}

	func host(withID id: UUID) -> HostedVM? {
		hosted.values.first { $0.identity.id == id }
	}

	// Stop every hosted VM (quit path): optionally ask guests first, then force stragglers,
	// and wait for the hosts to drain. Every host is asked at once and every stop is bounded
	// (E66): a vmhost that stopped answering costs the quit one deadline, never one per host,
	// and must never make the daemon unquittable by stalling the terminate reply (E5). One
	// that misses its shut down's deadline is listed as not responding and skips the force
	// pass (it would only cost another deadline), and the grace ends once only hosts that
	// failed or don't answer remain. Those are LEFT RUNNING (the next daemon re-adopts them)
	// and returned, for the caller to offer ending their processes (C9) — or, with
	// `endingUnanswered` (Shut Down All & Quit, K12), ended here like a confirmed End Process,
	// returning only the ones that could not be. The drain doesn't wait for them.
	@discardableResult
	public func stopAllHosted(
		softFirst: Bool, graceSeconds: Double, endingUnanswered: Bool = false
	) async -> [String] {
		let deadline = forceStopDeadline
		// The hosts that missed a stop's deadline in this pass.
		var unanswered: Set<String> = []
		if softFirst {
			let refused = await fanOut(to: hosted, skippingUnresponsive: true) {
				name, host -> Error? in
				do {
					try await host.client.stop(vm: name, mode: .soft, deadline: deadline)
					return nil
				} catch {
					return error
				}
			}
			var failed: Set<String> = []
			for (name, error) in refused {
				guard let error else { continue }
				failed.insert(name)
				MachmanLogger.log(.passiveError,
					"quit: shut down of \(name) failed (\(error))")
				if (error as? MachmanError)?.code == .timeout, let host = hosted[name] {
					unanswered.insert(name)
					markUnresponsive(host, reason: "missed its shut down deadline")
				}
			}
			_ = await poll(every: .milliseconds(250), for: .seconds(graceSeconds)) {
				hosted.allSatisfy { failed.contains($0.key) || $0.value.unresponsive }
			}
		}
		let forced = await fanOut(
			to: hosted.filter { !unanswered.contains($0.key) }, skippingUnresponsive: false
		) { name, host -> Error? in
			do {
				try await self.stopHosted(host, name: name, mode: .force)
				return nil
			} catch {
				return error
			}
		}
		var failed = unanswered
		for (name, error) in forced {
			guard let error else { continue }
			failed.insert(name)
			MachmanLogger.log(.passiveError,
				"quit: force stop of \(name) failed (\(error)) — leaving it running")
		}
		_ = await poll(every: .milliseconds(250), for: .seconds(10)) {
			Set(hosted.keys).subtracting(failed).isEmpty
		}
		let left = hosted.filter { failed.contains($0.key) }
		guard endingUnanswered else { return left.keys.sorted() }
		// Only the ones that don't answer: a host that refused its stop is still answering.
		let unanswering = left.filter { unanswered.contains($0.key) || $0.value.unresponsive }
		let ended = await fanOut(to: unanswering, skippingUnresponsive: false) { name, host in
			do {
				try await self.endUnresponsiveHost(host, name: name)
				return true
			} catch {
				MachmanLogger.log(.passiveError,
					"quit: couldn't end \(name)'s vmhost (\(error)) — leaving it running")
				return false
			}
		}
		return left.keys.filter { ended[$0] != true }.sorted()
	}

	// Asks every host at once (PR23): one main-actor Task per host, each suspending inside its
	// own call with its own deadline, so they overlap and a stalled host costs the pass one
	// deadline, never one per host (E20, E43, E66). With `skippingUnresponsive` a host listed
	// as not responding isn't asked and has no answer.
	func fanOut<Answer>(
		to hosts: [String: HostedVM], skippingUnresponsive: Bool,
		_ ask: @escaping @MainActor (String, HostedVM) async -> Answer
	) async -> [String: Answer] {
		let asks = hosts.filter { !(skippingUnresponsive && $0.value.unresponsive) }
			.map { name, host in (name, Task { await ask(name, host) }) }
		var answers: [String: Answer] = [:]
		for (name, answer) in asks {
			answers[name] = await answer.value
		}
		return answers
	}

	// The one wait loop of the host table (Q36): looks at `done` every `interval` until it
	// holds or `timeout` has passed on the router's clock, and says which. `done` looks first,
	// so a wait that is already over costs nothing; it may throw to end the wait early.
	func poll(
		every interval: Duration, for timeout: Duration, until done: () async throws -> Bool
	) async rethrows -> Bool {
		let expired = expiry(after: timeout)
		while true {
			if try await done() { return true }
			guard !expired() else { return false }
			try? await clock.sleep(for: interval)
		}
	}

	// A deadline `duration` from now on the router's clock: true once it has passed (Q40).
	func expiry(after duration: Duration) -> @Sendable () -> Bool {
		let clock = self.clock
		return expiryOf(clock, after: duration)
	}

	func waitForHostGone(id: UUID, timeout: Duration) async -> Bool {
		await poll(every: .milliseconds(50), for: timeout) { host(withID: id) == nil }
	}

	// The wait for a host to be gone (E12): a start meeting one that ran and stopped, and the
	// end of an outdated idle host, give it hostExitGrace; one that overstays — still
	// draining an import — is still shutting down.
	func waitOutExit(of host: HostedVM, name: String) async throws {
		guard await waitForHostGone(id: host.identity.id, timeout: hostExitGrace) else {
			throw stillShuttingDown(name)
		}
	}

	func stillShuttingDown(_ name: String) -> MachmanError {
		MachmanError(
			code: .invalidState, message: "\(name) is still shutting down — try again in a moment")
	}

	// A host on its way out (E52): its VM ran and stopped (or failed), or its connection
	// already dropped. A call forwarded to it now dies with it ("The connection was lost"),
	// and a stop-first edit must not take a VM the clients list stopped for a running one.
	func isLeaving(_ host: HostedVM) -> Bool {
		host.exitingAfterRun || host.reconnectTask != nil
	}

	// Whether a call waits a leaving host out before it goes anywhere — one rule for routed
	// calls and stop-first edits. Not while the host still works for a claim on its VM: an
	// import it drains into its stopped VM (E34) keeps it serving the VM's config until it
	// exits, past any grace, so a routed call goes to it and a stop-first edit answers the
	// claim at once (review F15). A dropped connection is waited out whatever holds the VM.
	func isWaitedOut(_ host: HostedVM) -> Bool {
		guard isLeaving(host) else { return false }
		return host.reconnectTask != nil || claims.refusal(for: host.identity.name) == nil
	}

	// Waits, up to hostExitGrace, for a leaving host to be gone, reconnected and serving its
	// run again, or working for a claim. One whose run is over and that overstays is still
	// shutting down; one leaving only because its connection dropped is not responding — at
	// once when it is listed so, else once the grace runs out (its VM still runs).
	func waitOutLeaving(_ host: HostedVM, name: String) async throws {
		let settled = try await poll(every: .milliseconds(50), for: hostExitGrace) {
			guard let current = self.host(withID: host.identity.id), isWaitedOut(current) else {
				return true
			}
			if current.unresponsive, current.reconnectTask != nil { throw notResponding(name) }
			return false
		}
		// Out of time: nothing suspended since the last look, so the host is still leaving.
		guard settled else {
			let exiting = self.host(withID: host.identity.id)?.exitingAfterRun ?? false
			throw exiting ? stillShuttingDown(name) : notResponding(name)
		}
	}

	// A stop for a VM its vmhost runs (E36). Shut Down asks the guest through the host, so
	// one listed as not responding is refused at once instead of after the call's deadline.
	// Force Stop is bounded: a host that misses the bound is marked not responding and the
	// stop answers `timeout` — the clients' cue to ask about ending its process
	// (vm.process.end, C9). Nothing here ends a process.
	func stopHosted(_ host: HostedVM, name: String, mode: StopMode) async throws {
		switch mode {
		case .soft:
			guard !host.unresponsive else {
				throw MachmanError(
					code: .invalidState, message: "\(name) is not responding — use Force Stop")
			}
			try await host.client.stop(vm: name, mode: .soft)
		case .force:
			do {
				try await host.client.stop(vm: name, mode: .force, deadline: forceStopDeadline)
			} catch let error as MachmanError where error.code == .timeout {
				markUnresponsive(host, reason: "missed its force stop deadline")
				throw MachmanError(
					code: .timeout, message: "\(name) isn’t answering, so it didn’t stop")
			}
		}
	}

	// MARK: - Ending a vmhost (C9)

	// What the VM's clients hear once Machman ended its vmhost: the stop is the run's end,
	// and hostGone announces it like any other.
	nonisolated static let endedProcessWarning =
		"Its process wasn’t answering, so Machman ended it."

	private func cantEnd(_ name: String) -> MachmanError {
		MachmanError(
			code: .invalidState,
			message: "\(name) is not responding, and Machman can’t end its process")
	}

	// A hosted vmhost listed as not responding: end it, then wait (bounded) for hostGone, so
	// the reply comes after the VM lists as stopped. The death watch or the dropped socket
	// does the cleanup, as for any exit.
	func endUnresponsiveHost(_ host: HostedVM, name: String) async throws {
		guard endHost(host) else { throw cantEnd(name) }
		MachmanLogger.log(.passiveWarning,
			"ended \(name)'s vmhost: it didn't answer, and the user confirmed ending it")
		registry.events.emit(.log(vm: name, level: .warning, message: Self.endedProcessWarning))
		if !(await waitForHostGone(id: host.identity.id, timeout: hostExitGrace)) {
			MachmanLogger.log(.passiveWarning, "\(name)'s vmhost was ended but is still listed")
		}
	}

	// A vmhost that answers on the VM's socket but could never be adopted: end whoever holds
	// the socket, if it is a vmhost. Nothing hosts it, so the list changes here.
	func endUnadoptedHost(_ name: String) async throws {
		let path = hostSocketPath(for: name)
		guard endSocketHolder(path) else { throw cantEnd(name) }
		MachmanLogger.log(.passiveWarning,
			"ended the vmhost on \(name)'s socket: it didn't answer, and the user confirmed it")
		registry.events.emit(.log(vm: name, level: .warning, message: Self.endedProcessWarning))
		_ = await poll(every: .milliseconds(50), for: hostExitGrace) {
			!UDSListener.isLive(path: path)
		}
		unadoptable.remove(name)
		registry.events.emit(.stateChanged(vm: name, state: .stopped))
		registry.events.emit(.listChanged)
	}

	// SIGKILL for a vmhost by pid — only while that pid is still a MachmanVMHost process: a
	// pid captured at connect time may belong to something else once the vmhost is gone.
	// True when it is gone already.
	nonisolated static func killVMHost(pid: pid_t) -> Bool {
		if kill(pid, 0) != 0, errno == ESRCH { return true }
		guard VMHostProcess.isVMHost(pid) else { return false }
		return kill(pid, SIGKILL) == 0 || errno == ESRCH
	}

	// A host went away — cleanly (VM stopped, host exits) or by crash. Looked up by identity
	// and unlinking the STORED socket path, so both survive re-keying. Idempotent.
	func hostGone(id: UUID) {
		guard let name = hosted.first(where: { $0.value.identity.id == id })?.key,
			let host = hosted.removeValue(forKey: name) else { return }
		host.deathWatch?.invalidate()
		host.deathWatch = nil
		host.eventTask?.cancel()
		host.sshDiscoveryTask?.cancel()
		host.recoveryTask?.cancel()
		host.reconnectTask?.cancel()
		let client = host.client
		Task {
			await client.disconnect()
		}
		if let shadowRoot = host.identity.shadowRoot {
			// A clean stop of a safe run: absorb the session's history into the real config
			// (single-writer safe — the host is gone), then discard the whole shadow. Before
			// reload so the daemon's fresh read sees the absorbed values.
			SafeRun.absorbShadowHistory(
				realDir: machmanVMDir + "/" + name, shadowDir: shadowRoot + "/" + name)
			try? FileManager.default.removeItem(atPath: shadowRoot)
		}
		registry.reload(name: name)
		// Never a live socket: a new run may already serve the path (E8), or publish there
		// right now — the removal waits its turn (review F13).
		_ = BoundSocket.removeIfDead(host.identity.socketPath)
		registry.events.emit(.stateChanged(vm: name, state: .stopped))
		registry.events.emit(.listChanged)
	}
}

// The router's clock opened to its concrete type, whose instants compare.
private func expiryOf<C: Clock<Duration>>(_ clock: C, after duration: Duration)
	-> @Sendable () -> Bool {
	let end = clock.now.advanced(by: duration)
	return { clock.now >= end }
}
