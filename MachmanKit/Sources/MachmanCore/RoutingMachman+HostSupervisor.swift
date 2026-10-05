//
//  RoutingMachman+HostSupervisor.swift
//  MachmanCore
//
//  The router's host table and each vmhost's life in it: spawning and adopting a host,
//  its event subscription, reconnecting a dropped connection, stall marks (E20), the
//  quit path's stop-all, and hostGone.
//

import Foundation
import AppKit
import MachmanAPI
import MachmanClient

extension RoutingMachman {
	// Everything the daemon knows about one vmhost, fixed at spawn/adopt time. Stored, never
	// recomputed: hostGone unlinks identity.socketPath and closures capture identity.id, so
	// both survive any re-keying of `hosted` (safe mode re-keys on save-as-new, and re-points
	// socketPath when the vmhost moved its socket to the saved VM's path).
	struct HostIdentity {
		let id: UUID
		var name: String
		var socketPath: String
		var isSafe = false           // a safe-mode run (vm.start {safe:true})
		var shadowRoot: String?      // that safe run's shadow copy (SafeRun)
		// The MAC the guest is actually using — captured at spawn from the config, at adopt
		// from the host's own reply (they can differ after a safe-save promotion).
		var macInUse: String?
		// The library a safe run saves into: its vmhost's --library, set at spawn. nil for a
		// re-attached run, whose vmhost an earlier daemon handed this daemon's own.
		var library: String?
	}

	final class HostedVM {
		// var: safe-mode re-attach (startup sweep) and safeSave re-keying mutate its fields.
		// Safe because every closure captures identity.id (a value), never the struct.
		var identity: HostIdentity
		// var: a dropped connection to a live host is replaced (E8).
		var client: RemoteMachman
		var reconnectTask: Task<Void, Never>?
		// The spawned standalone app; nil for adopted hosts (their only death detector is the
		// socket disconnect, same as before). deathWatch routes isTerminated to hostGone —
		// invalidate it BEFORE forceTerminate on failure paths so a cleanup kill can't
		// re-enter (hostGone is idempotent anyway; this keeps the sequence obviously correct).
		let app: NSRunningApplication?
		var deathWatch: NSKeyValueObservation?
		var eventTask: Task<Void, Never>?
		// Done once the host has this daemon's subscription (E9): a start is forwarded only
		// after it, so nothing the boot emits goes to a bus nobody hears.
		var eventsSubscribed: Task<Void, Never>?
		// SSH address discovery (1.0.5): daemon memory only, rebuilt after restarts by
		// the adopt path; served as a VMInfo overlay like safeRun.
		var sshAnswer: SSHDiscovery.Answer?
		var sshDiscoveryTask: Task<Void, Never>?
		// …and whether the guest's sshd actually answers (1.0.6). Also daemon memory:
		// it describes THIS run, so a stopped VM has no reachability at all.
		var sshReach: SSHInfo.Reachability = .unknown
		var sshReachDetail: String?
		var sshReadySince: Date?
		// E20: the host's last vm.get answer — what clients see while it misses its answer
		// deadline, marked unresponsive — and the watcher that notices it answering again.
		var lastAnswer: VMInfo? {
			didSet { if let state = lastAnswer?.state { lastState = state } }
		}
		// The VM's state as the host last told it: a stateChanged event or an answer (V7:
		// the agent's quit asks whether VMs run, not whether hosts exist).
		var lastState: VMState?
		var unresponsive = false
		var recoveryTask: Task<Void, Never>?
		// Whether this host ever ran its VM (E12): an idle host from a start whose forward
		// never happened can take a new start; one whose run stopped is exiting.
		var sawRun = false

		// A start this daemon forwarded succeeded: the VM runs, whether or not its running
		// event got here first (a later event still moves lastState on).
		func markStarted() {
			sawRun = true
			lastState = .running
		}
		// The disk files a start this daemon made left unattached (its disabled entries), or
		// nil for a start it did not make (an adopted host). The run attached every other
		// entry, whatever the flags say now: vm.setEnabled edits a running VM's config but
		// detaches nothing (C5). These paths never move — Save as New VM moves only what
		// the run attached — so they survive its re-keying.
		var unattachedDisks: Set<String>?

		// What the vmhost answered hello with: "<its own bundle version>-vmhost" since 1.0.12;
		// an older one echoed the spawning daemon's version, or "dev" under a launch agent.
		var version: String { client.hello.daemonVersion }

		init(
			identity: HostIdentity, client: RemoteMachman,
			app: NSRunningApplication?, deathWatch: NSKeyValueObservation?
		) {
			self.identity = identity
			self.client = client
			self.app = app
			self.deathWatch = deathWatch
		}
	}

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
	// the agent — as does work the agent runs itself on a VM that runs nothing (C13). One
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
			holders[name] = SessionHolder(vm: name, activity: kind.activity, promptsItself: false)
		}
		for vm in registry.list() where holders[vm.name] == nil && registry.isInstalling(vm) {
			holders[vm.name] = SessionHolder(
				vm: vm.name, activity: "is installing macOS", promptsItself: false)
		}
		return holders.values.sorted { $0.vm < $1.vm }
	}

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
			if UDSListener.isLive(path: socketPath) { unadoptable.insert(name) }
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

	// Fire-and-forget adoption for the read paths; a no-op while one is in flight.
	func scheduleAdoption(_ name: String) {
		guard adoptions[name] == nil else { return }
		Task { _ = try? await self.adoptLiveHost(name) }
	}

	// The one adoption path — startup, probe-adopt and on demand: connect, ask the host once
	// (bounded; its reply is its first last answer), adopt, and re-attach the safe run it
	// may be serving.
	func connectAndAdopt(name: String, socketPath: String) async throws -> HostedVM {
		var identity = HostIdentity(id: UUID(), name: name, socketPath: socketPath)
		adoptionAttempts += 1
		let client = try await connectHost(identity: identity)
		var reply: VMInfo?
		do {
			reply = try await client.vm(named: name, deadline: hostProbeDeadline)
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

	// Stop every hosted VM (quit path): optionally ask guests first, then force stragglers,
	// and wait for the hosts to drain. Every per-host stop is bounded: a vmhost that stopped
	// answering fails its call after the deadline, is logged, and is LEFT RUNNING (the quit
	// prompt's leave-VMs-running semantics; the next daemon re-adopts it) — one wedged host
	// must never make the daemon unquittable by stalling the terminate reply (E5). Returns
	// the VMs whose force stop failed and still run, for the caller to offer ending their
	// processes (C9); the drain doesn't wait for them.
	@discardableResult
	public func stopAllHosted(softFirst: Bool, graceSeconds: Double) async -> [String] {
		if softFirst {
			for (name, host) in hosted {
				guard hosted[name] != nil else { continue }   // exited during the loop
				do {
					try await host.client.stop(vm: name, mode: .soft, deadline: forceStopDeadline)
				} catch {
					MachmanLogger.log(.passiveError,
						"quit: soft stop of \(name) failed (\(error)) — leaving it running")
				}
			}
			let deadline = Date().addingTimeInterval(graceSeconds)
			while Date() < deadline, !hosted.isEmpty {
				try? await Task.sleep(for: .milliseconds(500))
			}
		}
		var failed: Set<String> = []
		for (name, host) in hosted {
			guard hosted[name] != nil else { continue }
			do {
				try await stopHosted(host, name: name, mode: .force)
			} catch {
				failed.insert(name)
				MachmanLogger.log(.passiveError,
					"quit: force stop of \(name) failed (\(error)) — leaving it running")
			}
		}
		let deadline = Date().addingTimeInterval(10)
		while Date() < deadline, !Set(hosted.keys).subtracting(failed).isEmpty {
			try? await Task.sleep(for: .milliseconds(250))
		}
		return failed.filter { hosted[$0] != nil }.sorted()
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

	// A start that never connected. Its reason reads as a sentence, like the relayed errors
	// that can take its place ("Can’t connect: …", "It speaks API version 2 instead of 1").
	nonisolated static let hostNeverAnswered = "It never answered"
	nonisolated static let hostQuitWhileStarting = "It quit while starting"
	nonisolated static func hostDidNotStart(_ name: String, reason: String) -> String {
		"Machman VM for \(name) didn’t start: \(reason)"
	}

	// The identity is minted by the CALLER (safe starts pre-set isSafe/shadowRoot) before
	// any closure is built: termination and disconnect handlers capture the identity's id,
	// never the (re-keyable) name. dataDir is the vmhost's scan root — the library for a
	// normal run, the shadow run root for a safe one.
	func spawnHost(
		identity: HostIdentity, dataDir: String, extraArguments: [String] = []
	) async throws -> HostedVM {
		let name = identity.name
		guard let vmhost = locateVMHost() else {
			MachmanLogger.log(.passiveError,
				"MachmanVMHost.app not found (embedded or beside \(Bundle.main.bundleURL.path))")
			throw MachmanError(
				code: .internalError,
				message: "Machman VM is missing from this copy of Machman — reinstall Machman")
		}
		// Standalone, never a child: the vmhost is its own TCC responsible process by
		// construction — the same identity story as a launchd-started host.
		let configuration = NSWorkspace.OpenConfiguration()
		configuration.createsNewApplicationInstance = true   // one instance per VM, shared id
		configuration.activates = false
		configuration.arguments = [
			"--data-dir", dataDir, "--vm", name, "--socket", identity.socketPath,
		] + extraArguments
		// OpenConfiguration.environment REPLACES the child's environment (no inheritance),
		// which scrubs any MACHMAN_DATA_DIR override for free. The bundle id identifies the
		// suite and the bundle version the vmhost's build (E22); MACHMAN_VERSION is only the
		// fallback for an unversioned build.
		configuration.environment = ["MACHMAN_VERSION": daemonVersion]

		let app: NSRunningApplication
		do {
			app = try await NSWorkspace.shared.openApplication(
				at: vmhost.appURL, configuration: configuration)
		} catch {
			throw MachmanError(
				code: .internalError,
				message: "Couldn’t open Machman VM for \(name): "
					+ MachmanError.userMessage(for: error))
		}
		let hostID = identity.id
		let deathWatch = app.observe(\.isTerminated, options: [.new]) { [weak self] app, _ in
			guard app.isTerminated else { return }
			Task { @MainActor [weak self] in
				self?.hostGone(id: hostID)
			}
		}

		var lastError = Self.hostNeverAnswered
		for _ in 0..<40 {
			try? await Task.sleep(for: .milliseconds(250))
			guard !app.isTerminated else {
				lastError = Self.hostQuitWhileStarting
				break
			}
			do {
				let client = try await connectHost(identity: identity)
				return HostedVM(
					identity: identity, client: client, app: app, deathWatch: deathWatch)
			} catch {
				lastError = MachmanError.userMessage(for: error)
			}
		}
		deathWatch.invalidate()
		app.forceTerminate()
		throw MachmanError(
			code: .internalError, message: Self.hostDidNotStart(name, reason: lastError))
	}

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

	// The subscription is made before anything else reaches the host, and `eventsSubscribed`
	// says when the host has it (E9). Each event goes on by the line the host sent it in, so a
	// newer vmhost's event types and fields reach clients whole (A10); the side effects here
	// read the decoded event.
	private func subscribeEvents(_ host: HostedVM) {
		let id = host.identity.id
		let client = host.client
		host.eventTask?.cancel()
		let subscription = Task { await client.eventLines() }
		host.eventsSubscribed = Task { _ = await subscription.value }
		host.eventTask = Task { [weak self] in
			let stream = await subscription.value
			for await forwarded in stream {
				guard let self = self else { return }
				let event = forwarded.event
				guard self.host(withID: id) != nil || Self.passesBeforeHosted(event) else {
					continue
				}
				if case .stateChanged(_, let state) = event, let host = self.host(withID: id) {
					host.lastState = state
				}
				if case .stateChanged(_, let state) = event, state.isRunning,
					let host = self.host(withID: id) {
					host.sawRun = true
					// The guest just came up (boot or reboot): (re)start discovery.
					self.startSSHDiscovery(host)
				}
				if case .sshChanged(let changed) = event {
					self.reconcileReverseKey(vm: changed)
					if let host = self.host(withID: id),
						host.sshAnswer == nil || host.sshReach == .unknown {
						// A fresh report can mean sshd just appeared — probe again now.
						// (reach == .unknown means the guest had not run the script when
						// this run started, so readiness was never being watched.)
						self.startSSHDiscovery(host)
					}
					// Report ingestion may have changed users/keys the managed file pins.
					self.scheduleSSHHostConfigWrite()
				}
				self.registry.events.emit(event, line: forwarded.line)
			}
		}
	}

	// What a spawned host's events may say before it is hosted (its spawn and start window):
	// its boot's log lines (E9) and a newer host's unknown events. Its own state and list
	// changes are not passed on: until the start returns, the router lists the VM as starting
	// and then announces the run itself, and a running state or a reload in between would
	// flicker the state and toast a start twice (O-6a).
	static func passesBeforeHosted(_ event: VMEvent) -> Bool {
		switch event {
		case .log, .unknown:
			return true
		case .stateChanged, .listChanged, .installPhaseChanged, .copyProgress,
			.operationChanged, .sshChanged, .setupChanged:
			return false
		}
	}

	// Hands a host its VM's start once the host has this daemon's subscription (E9), so the
	// boot's own events — a uart it could not attach, a headless start — reach clients.
	func forwardStart(_ host: HostedVM, name: String, options: StartOptions) async throws {
		if host.eventsSubscribed == nil { subscribeEvents(host) }
		await host.eventsSubscribed?.value
		try await host.client.start(vm: name, options: options)
	}

	func host(withID id: UUID) -> HostedVM? {
		hosted.values.first { $0.identity.id == id }
	}

	// A host went away — cleanly (VM stopped, host exits) or by crash. Looked up by identity
	// and unlinking the STORED socket path, so both survive re-keying. Idempotent.
	private func hostGone(id: UUID) {
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
				realConfigPath: machmanVMDir + "/" + name + "/config",
				shadowConfigPath: shadowRoot + "/" + name + "/config")
			try? FileManager.default.removeItem(atPath: shadowRoot)
		}
		registry.reload(name: name)
		// Never a live socket: a new run may already serve the path (E8).
		if !UDSListener.isLive(path: host.identity.socketPath) {
			unlink(host.identity.socketPath)
		}
		registry.events.emit(.stateChanged(vm: name, state: .stopped))
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

	// Transitions only: each one logs, announces itself with listChanged (clients reload on
	// it — the only way a recovered VM's mark ever clears), and starts or ends the watcher.
	private func markUnresponsive(_ host: HostedVM, reason: String? = nil) {
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
