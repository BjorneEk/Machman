//
//  RoutingMachman.swift
//  MachmanCore
//
//  The daemon's MachmanControlling once VMs run in their own processes. Config-plane work for
//  stopped VMs is handled locally; `start` spawns the embedded MachmanVMHost and from then on
//  EVERY operation for that VM proxies to its host over the per-VM socket (single writer per
//  config file at all times). Host event streams are re-emitted into the daemon's bus so
//  clients keep exactly one subscription. macOS installs stay daemon-side (the VM is stopped
//  during an install by definition), so starts are refused while installing and installs are
//  refused while hosted.
//

import Foundation
import AppKit
import Virtualization
import MachmanAPI
import MachmanClient

@MainActor
public final class RoutingMachman: MachmanControlling {
	private let registry: VMRegistry
	private let local: LocalMachman
	private let daemonVersion: String
	// Injected (not built here) so unit tests can never touch ~/Library/LaunchAgents by
	// construction. nil = no agents are written; policy toggles still persist.
	private let launchAgents: LaunchAgentManager?
	// Same rule for ~/.ssh: injected by the daemon, nil in tests — SSH switches still
	// persist, only the host-side files stay untouched.
	private let sshHostConfig: SSHHostConfigWriter?

	// Everything the daemon knows about one vmhost, fixed at spawn/adopt time. Stored, never
	// recomputed: hostGone unlinks identity.socketPath and closures capture identity.id, so
	// both survive any future re-keying of `hosted` (safe mode re-keys on save-as-new).
	struct HostIdentity {
		let id: UUID
		var name: String
		let socketPath: String
		var isSafe = false           // inert until safe mode (phase 6)
		var shadowRoot: String?      // inert until safe mode (phase 6)
		// The MAC the guest is actually using — captured at spawn from the config, at adopt
		// from the host's own reply (they can differ after a safe-save promotion).
		var macInUse: String?
	}

	final class HostedVM {
		// var: safe-mode re-attach (startup sweep) and safeSave re-keying mutate its fields.
		// Safe because every closure captures identity.id (a value), never the struct.
		var identity: HostIdentity
		let client: RemoteMachman
		// The spawned standalone app; nil for adopted hosts (their only death detector is the
		// socket disconnect, same as before). deathWatch routes isTerminated to hostGone —
		// invalidate it BEFORE forceTerminate on failure paths so a cleanup kill can't
		// re-enter (hostGone is idempotent anyway; this keeps the sequence obviously correct).
		let app: NSRunningApplication?
		var deathWatch: NSKeyValueObservation?
		var eventTask: Task<Void, Never>?
		// SSH address discovery (1.0.5): daemon memory only, rebuilt after restarts by
		// the adopt path; served as a VMInfo overlay like safeRun.
		var sshAnswer: SSHDiscovery.Answer?
		var sshDiscoveryTask: Task<Void, Never>?
		// …and whether the guest's sshd actually answers (1.0.6). Also daemon memory:
		// it describes THIS run, so a stopped VM has no reachability at all.
		var sshReach: SSHInfo.Reachability = .unknown
		var sshReachDetail: String?
		var sshReadySince: Date?

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
	private var hosted: [String: HostedVM] = [:]   // keyed by VM name

	// The start-window reservation. `hosted[name]` is written only after the NSWorkspace
	// launch, the connect poll, and (for safe runs) a possibly minutes-long shadow build —
	// so a guard that reads only `hosted` has a window where a booting VM looks idle: a
	// second start would adopt-then-kill the half-spawned host, a delete would remove the
	// directory under it, and a concurrent purgeDeadShadows would eat the in-flight shadow
	// build. A name lives in here from start()'s first line until the start completed or
	// failed; main-actor confinement makes the check-then-insert atomic. Internal (not
	// private) as a test seam — tests reserve a name to exercise the guards.
	var pendingStarts: Set<String> = []

	public init(
		registry: VMRegistry, daemonVersion: String,
		launchAgents: LaunchAgentManager? = nil,
		sshHostConfig: SSHHostConfigWriter? = nil
	) {
		self.registry = registry
		self.local = LocalMachman(registry: registry)
		self.daemonVersion = daemonVersion
		self.launchAgents = launchAgents
		self.sshHostConfig = sshHostConfig
	}

	var hostedNames: [String] { Array(hosted.keys) }

	// Test seam: lets tests mutate an adopted host's identity (what the sweep's re-attach
	// path does) without fabricating run roots.
	func hostForTesting(_ name: String) -> HostedVM? { hosted[name] }

	public var hasHostedVMs: Bool { !hosted.isEmpty }

	// Adopt vmhosts left behind by an earlier daemon: a live host answers on its socket and
	// keeps running (its VM never noticed the daemon restart); a stale socket is reclaimed.
	// This is the daemon's whole startup reconciliation, so it also has to cope with the
	// ungraceful cases — force quit, crash, power loss — where nothing got to clean up.
	public func adoptExistingHosts() async {
		pruneDeadHostSockets()
		for vm in registry.list() {
			let name = vm.name
			guard hosted[name] == nil else { continue }
			let socketPath = Self.hostSocketPath(for: name)
			guard FileManager.default.fileExists(atPath: socketPath) else { continue }
			var identity = HostIdentity(id: UUID(), name: name, socketPath: socketPath)
			do {
				let client = try await connectHost(identity: identity)
				// The host's reply is the MAC the guest is actually using — it can differ
				// from the daemon's stale view (safe-save promotions rewrite it mid-run).
				identity.macInUse = (try? await client.vm(named: name))?.macAddress
				adopt(identity: identity, client: client)
				MachmanLogger.log(.log, "adopted running vmhost for \(name)")
			} catch {
				unlink(socketPath)
			}
		}
	}

	// Runs at daemon startup, strictly AFTER adoptExistingHosts: adoption is what turns a
	// surviving safe vmhost back into hosted[vm], and the socket peer pid is what proves a
	// marker belongs to that exact process. Everything else follows the rule: a run dir
	// only matters while its VM is currently running in safe mode.
	public func sweepSafeRuns() {
		sweepSafeRuns(isPidAlive: SafeRun.defaultPidAlive)
	}

	func sweepSafeRuns(isPidAlive: (Int32) -> Bool) {
		let fm = FileManager.default
		guard let entries = try? fm.contentsOfDirectory(atPath: machmanSafeDir) else { return }
		for entry in entries.sorted() where entry.hasPrefix(SafeRun.runPrefix) {
			let runRoot = machmanSafeDir + "/" + entry
			let marker = SafeRun.readMarker(runRoot: runRoot)
			let hostedPeer = marker.flatMap { hosted[$0.vm]?.client.peerPID }
			switch SafeRun.sweepVerdict(
				marker: marker, hostedPeerPID: hostedPeer, isPidAlive: isPidAlive) {
			case .reattach:
				guard let marker, let host = hosted[marker.vm] else { break }
				host.identity.isSafe = true
				host.identity.shadowRoot = runRoot
				MachmanLogger.log(.log, "re-attached safe run \(entry) to \(marker.vm)")
			case .delete:
				try? fm.removeItem(atPath: runRoot)
				MachmanLogger.log(.log, "swept dead safe run \(entry)")
			case .keep:
				MachmanLogger.log(.passiveWarning,
					"keeping undecidable safe run \(entry) (possibly live)")
			}
		}
	}

	// Runs at daemon startup, after adoptExistingHosts (same ordering reason as
	// sweepSafeRuns): whatever a crash-killed process left behind in a NON-hosted VM's
	// directory is stale by definition — payloads are ephemeral (regenerated at start),
	// and a disk-import staging file or a downloaded restore image belongs to an
	// operation that died with its process (none can be in flight here: requests are
	// held until this sweep finishes, and installs only ever run in the daemon). Hosted
	// VMs are skipped: the daemon never writes (or removes) inside a directory a vmhost
	// is serving.
	public func sweepStoppedVMLeftovers() {
		sweepStoppedVMLeftovers(isSocketLive: { UDSListener.isLive(path: $0) })
	}

	func sweepStoppedVMLeftovers(isSocketLive: (String) -> Bool) {
		for vm in registry.list() where hosted[vm.name] == nil {
			// An unadopted vmhost (a launch agent racing daemon startup, or one whose
			// socket appeared after adoption ran) may be serving this directory right
			// now — the socket is the truth, not the hosted map.
			guard !isSocketLive(Self.hostSocketPath(for: vm.name)) else { continue }
			GuestSetupInstaller.removePayload(for: vm.config)
			DiskImport.sweepStaleStaging(vmDir: vm.config.vmDirPath())
			let ipsw = vm.config.configFilePath(file: MacInstaller.restoreImageFileName)
			if FileManager.default.fileExists(atPath: ipsw) {
				try? FileManager.default.removeItem(atPath: ipsw)
				MachmanLogger.log(.log, "removed abandoned restore image for \(vm.name)")
			}
		}
	}

	// Belt for the sweep: any start clears provably dead shadow leftovers for this VM, so a
	// later daemon restart cannot misread them against the new run. Never touches a
	// live-pid run root — a live pid means some vmhost owns the name's socket, and the
	// probe/hosted guards arbitrate that. A pid-NIL root can be an in-flight safe start's
	// shadow build (marker written, pid stamped only after the spawn) — safe to purge here
	// solely because the only caller is start(), which runs under the pendingStarts
	// reservation: a second start of the same name is refused before it can reach this.
	func purgeDeadShadows(for name: String, isPidAlive: (Int32) -> Bool = SafeRun.defaultPidAlive) {
		let fm = FileManager.default
		guard let entries = try? fm.contentsOfDirectory(atPath: machmanSafeDir) else { return }
		for entry in entries where entry.hasPrefix(SafeRun.runPrefix) {
			let runRoot = machmanSafeDir + "/" + entry
			guard let marker = SafeRun.readMarker(runRoot: runRoot), marker.vm == name else {
				continue
			}
			if let pid = marker.pid, isPidAlive(pid) { continue }
			try? fm.removeItem(atPath: runRoot)
			MachmanLogger.log(.log, "purged stale safe run \(entry) for \(name)")
		}
	}

	// Stop every hosted VM (quit path): optionally ask guests first, then force stragglers,
	// and wait for the hosts to drain.
	public func stopAllHosted(softFirst: Bool, graceSeconds: Double) async {
		if softFirst {
			for name in Array(hosted.keys) {
				try? await stop(vm: name, mode: .soft)
			}
			let deadline = Date().addingTimeInterval(graceSeconds)
			while Date() < deadline, !hosted.isEmpty {
				try? await Task.sleep(for: .milliseconds(500))
			}
		}
		for name in Array(hosted.keys) {
			try? await stop(vm: name, mode: .force)
		}
		let deadline = Date().addingTimeInterval(10)
		while Date() < deadline, !hosted.isEmpty {
			try? await Task.sleep(for: .milliseconds(250))
		}
	}

	// MARK: - Host plumbing

	static func hostSocketPath(for name: String) -> String {
		machmanVMSocketPath(vm: name)
	}

	// Sockets are only unlinked on an orderly exit, so anything killed leaves one behind — and a
	// leftover for a VM since renamed or deleted would never be probed by adoption, which only
	// looks at VMs that still exist. Sweep the whole runtime dir instead: control sockets
	// (vm-*.sock) and the per-port serial data-plane sockets (tty-*.sock) a crashed vmhost
	// leaves beside them. The dir is injectable so tests can sweep a scratch dir.
	private func pruneDeadHostSockets() {
		pruneDeadHostSockets(dir: machmanRuntimeDir)
	}

	func pruneDeadHostSockets(dir: String) {
		guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
			return
		}
		let vmhostPrefixes = ["vm-", "tty-"]
		for entry in entries
			where entry.hasSuffix(".sock") && vmhostPrefixes.contains(where: entry.hasPrefix) {
			let path = dir + "/" + entry
			guard !UDSListener.isLive(path: path) else { continue }
			unlink(path)
			MachmanLogger.log(.log, "removed stale vmhost socket \(entry)")
		}
	}

	// The identity is minted by the CALLER (safe starts pre-set isSafe/shadowRoot) before
	// any closure is built: termination and disconnect handlers capture the identity's id,
	// never the (re-keyable) name. dataDir is the vmhost's scan root — the library for a
	// normal run, the shadow run root for a safe one.
	private func spawnHost(
		identity: HostIdentity, dataDir: String, extraArguments: [String] = []
	) async throws -> HostedVM {
		let name = identity.name
		guard let vmhost = VMHostLocator.locate() else {
			throw MachmanError(
				code: .internalError,
				message: "MachmanVMHost.app not found (embedded or beside "
					+ "\(Bundle.main.bundleURL.path))")
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
		// suite; only the version handshake still travels by env.
		configuration.environment = ["MACHMAN_VERSION": daemonVersion]

		let app: NSRunningApplication
		do {
			app = try await NSWorkspace.shared.openApplication(
				at: vmhost.appURL, configuration: configuration)
		} catch {
			throw MachmanError(
				code: .internalError,
				message: "cannot launch vmhost for \(name): \(error.localizedDescription)")
		}
		let hostID = identity.id
		let deathWatch = app.observe(\.isTerminated, options: [.new]) { [weak self] app, _ in
			guard app.isTerminated else { return }
			Task { @MainActor [weak self] in
				self?.hostGone(id: hostID)
			}
		}

		var lastError = "vmhost never answered"
		for _ in 0..<40 {
			try? await Task.sleep(for: .milliseconds(250))
			guard !app.isTerminated else {
				lastError = "vmhost exited during startup"
				break
			}
			do {
				let client = try await connectHost(identity: identity)
				return HostedVM(
					identity: identity, client: client, app: app, deathWatch: deathWatch)
			} catch {
				lastError = "\(error)"
			}
		}
		deathWatch.invalidate()
		app.forceTerminate()
		throw MachmanError(
			code: .internalError, message: "vmhost for \(name) failed to start: \(lastError)")
	}

	func connectHost(identity: HostIdentity) async throws -> RemoteMachman {
		let hostID = identity.id
		return try await RemoteMachman(
			socketPath: identity.socketPath, clientName: "machman-agent-router",
			onDisconnect: { [weak self] in
				Task { @MainActor [weak self] in
					self?.hostGone(id: hostID)
				}
			})
	}

	func adopt(identity: HostIdentity, client: RemoteMachman) {
		let host = HostedVM(identity: identity, client: client, app: nil, deathWatch: nil)
		hosted[identity.name] = host
		subscribeEvents(host)
		// Adopted hosts are already running and may never emit another stateChanged —
		// this is how discovery (daemon memory) survives a daemon restart mid-run.
		startSSHDiscovery(host)
		registry.events.emit(.listChanged)
	}

	private func subscribeEvents(_ host: HostedVM) {
		let id = host.identity.id
		host.eventTask = Task { [weak self] in
			let stream = await host.client.events()
			for await event in stream {
				guard let self = self else { return }
				if case .stateChanged(_, let state) = event, state.isRunning,
					let host = self.host(withID: id) {
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
				self.registry.events.emit(event)
			}
		}
	}

	// MARK: - SSH discovery (1.0.5, daemon-side)

	private func host(withID id: UUID) -> HostedVM? {
		hosted.values.first { $0.identity.id == id }
	}

	// Host-side access follows the CURRENT key, always. A guest that re-runs the setup
	// script after an uninstall mints a fresh reverse key, which drops approval back to
	// pending — and the line installed for the old key has to go with it, or that key
	// keeps its way in with nothing in the UI offering to revoke it.
	private func reconcileReverseKey(vm name: String) {
		guard let writer = sshHostConfig, let marker = existingSSHMarker(name) else { return }
		Task { [weak self] in
			guard let self,
				let ssh = (try? await self.target(name).vm(named: name))?.ssh else { return }
			guard ssh.reverseState != .approved else { return }
			try? writer.setReverseKey(nil, marker: marker, vmName: name)
		}
	}

	// Bounded per-VM resolver in two phases, on one task keyed by identity.id (so
	// safe-save re-keying can't cross wires) and cancelled in hostGone:
	//
	//   1. the address — 5 s cadence while DHCP settles (2 min), then once a minute for
	//      as long as the VM stays hosted and unresolved. The address is a fact of the
	//      running VM whether or not anything listens on it, so nothing gates it.
	//   2. reachability — does the guest's sshd actually answer? Only for VMs whose guest
	//      has run the setup script (without a reported user there is nothing to connect
	//      as, and "waiting for SSH" would be noise on every other VM).
	private func startSSHDiscovery(_ host: HostedVM) {
		host.sshDiscoveryTask?.cancel()
		guard let mac = host.identity.macInUse else { return }
		let id = host.identity.id
		let name = host.identity.name
		let client = host.client
		host.sshReach = .unknown
		host.sshReachDetail = nil
		host.sshReadySince = nil
		host.sshDiscoveryTask = Task { [weak self] in
			// Whether this guest has SSH set up must be read from the process that OWNS
			// the config — the vmhost. The daemon's registry copy was parsed at scan time
			// and never sees the guest's first report, so asking it left readiness stuck
			// at "unknown" for exactly the run where the user just ran the script.
			let wantsSSH = (try? await client.vm(named: name))?.ssh?.guestUser != nil
			if wantsSSH, let self, let host = self.host(withID: id) {
				host.sshReach = .waiting
				self.registry.events.emit(.sshChanged(vm: name))
			}
			var attempt = 0
			var address: String?
			while !Task.isCancelled, address == nil {
				// Detached: the live loaders read /var/db and run arp — off the main actor.
				let answer = await Task.detached {
					SSHDiscovery.discoverLive(mac: mac)
				}.value
				guard let self, let host = self.host(withID: id) else { return }
				if let answer {
					if host.sshAnswer != answer {
						host.sshAnswer = answer
						self.registry.events.emit(.sshChanged(vm: name))
						// The alias's HostName just became known/changed.
						self.scheduleSSHHostConfigWrite()
					}
					address = answer.address
					break
				}
				attempt += 1
				try? await Task.sleep(for: attempt < 24 ? .seconds(5) : .seconds(60))
			}
			guard wantsSSH, let address else { return }
			await self?.probeSSHReadiness(id: id, name: name, address: address)
		}
	}

	// Phase 2. Tight while a guest is still booting, then slower, and bounded: a VM whose
	// sshd never comes up gets an answer ("unreachable", with the reason) instead of a
	// spinner that never stops. vm.ssh.refresh starts the whole thing over — that is what
	// the desktop's retry and session reconnect call.
	private func probeSSHReadiness(id: UUID, name: String, address: String) async {
		let deadline = Date().addingTimeInterval(180)
		var probes = 0
		while !Task.isCancelled {
			let answered = await SSHDiscovery.probeTCP(host: address, timeout: 1.5)
			guard let host = self.host(withID: id) else { return }
			if answered {
				host.sshReach = .ready
				host.sshReachDetail = nil
				host.sshReadySince = Date()
				registry.events.emit(.sshChanged(vm: name))
				return
			}
			if Date() >= deadline {
				host.sshReach = .unreachable
				host.sshReachDetail = "no answer on \(address):22 after 3 minutes"
				registry.events.emit(.sshChanged(vm: name))
				return
			}
			probes += 1
			try? await Task.sleep(for: probes < 15 ? .seconds(2) : .seconds(5))
		}
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
		unlink(host.identity.socketPath)
		registry.events.emit(.stateChanged(vm: name, state: .stopped))
		registry.events.emit(.listChanged)
	}

	// Config/window-plane routing: a hosted VM's own process, else the daemon-local engine.
	private func target(_ name: String) -> MachmanControlling {
		if let host = hosted[name] { return host.client }
		return local
	}

	// Whole-VM edits the framework fixes at start refuse rather than proxy while hosted.
	// A pending start counts as hosted: the vmhost is (or is about to be) reading the very
	// files these operations move, and its markRan whole-file save would silently revert
	// any daemon-side edit that slipped through the spawn window.
	private func refuseWhileHosted(_ name: String, _ action: String) throws {
		guard hosted[name] == nil else {
			throw MachmanError(code: .invalidState, message: "stop \(name) before \(action)")
		}
		guard !pendingStarts.contains(name) else {
			throw MachmanError(
				code: .invalidState, message: "\(name) is starting — wait before \(action)")
		}
	}

	// The hosted map only knows vmhosts this daemon spawned or adopted at its startup. A
	// launch-agent vmhost that bound its socket later is invisible to it — the VM lists as
	// stopped while a live guest runs from the directory. For destruction, the socket is
	// the truth (same probe launchAgents.remove gates its bootout on): refuse, and let the
	// next start — or the next daemon — adopt the host. The socket path is injectable so
	// tests can bind a stub listener (probeAdoptAndStart seam pattern).
	func refuseUnadoptedHost(_ name: String, _ action: String, socketPath: String? = nil) throws {
		let path = socketPath ?? Self.hostSocketPath(for: name)
		guard !UDSListener.isLive(path: path) else {
			throw MachmanError(
				code: .invalidState,
				message: "a vmhost is still running \(name) — stop it before \(action)")
		}
	}

	// MARK: - MachmanControlling

	public func hostCapabilities() async throws -> HostCapabilities {
		try await local.hostCapabilities()
	}

	public func listVMs() async throws -> [VMInfo] {
		var infos: [VMInfo] = []
		for vm in registry.list() {
			if let host = hosted[vm.name],
				var info = try? await host.client.vm(named: vm.name) {
				// The daemon-side overlays: only the router knows a run is safe, and only
				// it runs address discovery.
				if host.identity.isSafe { info.safeRun = true }
				overlaySSH(&info, from: host)
				infos.append(info)
				continue
			}
			infos.append(try await local.vm(named: vm.name))
		}
		return infos
	}

	public func vm(named name: String) async throws -> VMInfo {
		if let host = hosted[name], var info = try? await host.client.vm(named: name) {
			if host.identity.isSafe { info.safeRun = true }
			overlaySSH(&info, from: host)
			return info
		}
		return try await local.vm(named: name)
	}

	// The discovered address rides every VMInfo answer while the VM is hosted — attached
	// to the served ssh state, or as a minimal shell when the guest never reported.
	// The daemon's half of SSHInfo: what discovery found, and how this run is going.
	// Nothing is invented for a VM that never used SSH and has no address either — the
	// clients read a nil `ssh` as "SSH was never set up here".
	private func overlaySSH(_ info: inout VMInfo, from host: HostedVM) {
		guard host.sshAnswer != nil || info.ssh != nil else { return }
		var ssh = info.ssh ?? SSHInfo()
		if let answer = host.sshAnswer {
			ssh.address = answer.address
			ssh.addressSource = answer.source
			ssh.hostAddressForGuest = SSHDiscovery.hostAddress(seenFrom: answer.address)
		}
		ssh.reachability = host.sshReach
		ssh.reachabilityDetail = host.sshReachDetail
		ssh.readySince = host.sshReadySince
		info.ssh = ssh
	}

	public func createVM(template: String?) async throws -> VMInfo {
		try await local.createVM(template: template)
	}

	public func deleteVM(named name: String) async throws {
		try refuseWhileHosted(name, "deleting it")
		try refuseUnadoptedHost(name, "deleting it")
		// Capture the marker BEFORE the identity file dies with the VM dir.
		let sshMarker = existingSSHMarker(name)
		try await local.deleteVM(named: name)
		launchAgents?.remove(vm: name, canBootout: true)
		if let writer = sshHostConfig, let sshMarker {
			try? writer.setReverseKey(nil, marker: sshMarker, vmName: name)
		}
		scheduleSSHHostConfigWrite()
	}

	public func renameVM(named name: String, to newName: String) async throws {
		try refuseWhileHosted(name, "renaming it")
		try await local.renameVM(named: name, to: newName)
		// The managed ssh alias is name-keyed; regeneration re-keys the block (the
		// marker — and with it the reverse authorized_keys label — never changes).
		scheduleSSHHostConfigWrite()
		guard let launchAgents else { return }
		launchAgents.remove(vm: name, canBootout: true)
		if registry.vm(named: newName)?.config.startPolicy.autostart == true {
			do {
				try launchAgents.install(vm: newName)
			} catch {
				MachmanLogger.log(.passiveError,
					"cannot write launch agent for \(newName): \(error)")
			}
		}
	}

	public func setHardware(
		vm name: String, cpuCount: Int?, memoryBytes: UInt64?, nestedVirtualization: Bool?
	) async throws {
		try await target(name).setHardware(
			vm: name, cpuCount: cpuCount, memoryBytes: memoryBytes,
			nestedVirtualization: nestedVirtualization)
	}

	public func copyVM(
		vm name: String, newName: String?, diskIDs: [String]?, regenerateMAC: Bool
	) async throws -> VMInfo {
		// Cloning images under an active writer produces torn copies.
		try refuseWhileHosted(name, "copying it")
		return try await local.copyVM(
			vm: name, newName: newName, diskIDs: diskIDs, regenerateMAC: regenerateMAC)
	}

	// Refused while hosted, not proxied: the running guest keeps the old MAC, and conflict
	// tracking captures macInUse at spawn — a mid-run change would desynchronize both.
	public func regenerateMAC(vm name: String) async throws -> VMInfo {
		try refuseWhileHosted(name, "regenerating its MAC")
		return try await local.regenerateMAC(vm: name)
	}

	public func addDisk(vm name: String, _ disk: NewDisk) async throws {
		try await target(name).addDisk(vm: name, disk)
	}

	public func removeDisk(vm name: String, diskID: String) async throws {
		// Unlinking the backing file under a live VZ attachment is unsafe — stop first
		// (the guest would keep a ghost disk until shutdown, then the data is gone).
		try refuseWhileHosted(name, "removing its disks")
		try await local.removeDisk(vm: name, diskID: diskID)
	}

	// Import proxies deliberately: it is addDisk with a copy in front — the source is an
	// external file no attachment references, the owned image is NEW, and the config
	// addition is the hosted vmhost's to make (next-boot effect, like addDisk/addMount).
	public func importDisk(vm name: String, path: String) async throws -> VMInfo {
		try await target(name).importDisk(vm: name, path: path)
	}

	// Refused while hosted, not proxied or deferred: the copy reads an image the live VZ
	// attachment holds open read-write (torn owned copy — copyVM's refusal reason), and the
	// config rewire under that attachment makes the next boot silently switch disks.
	public func promoteDisk(vm name: String, diskID: String) async throws -> VMInfo {
		try refuseWhileHosted(name, "promoting its disks")
		return try await local.promoteDisk(vm: name, diskID: diskID)
	}

	public func addMount(vm name: String, path: String, tag: String, kind: String?) async throws {
		try await target(name).addMount(vm: name, path: path, tag: tag, kind: kind)
	}

	public func removeMount(vm name: String, mountID: String) async throws {
		try await target(name).removeMount(vm: name, mountID: mountID)
	}

	// Serial ports are fixed at VM start, so add/remove is refused while hosted (like MAC), but
	// setSerialLogging proxies to the live bridge.
	public func addConsolePort(vm name: String) async throws {
		try refuseWhileHosted(name, "changing its serial ports")
		try await local.addConsolePort(vm: name)
	}

	public func removeConsolePort(vm name: String) async throws {
		try refuseWhileHosted(name, "changing its serial ports")
		try await local.removeConsolePort(vm: name)
	}

	public func addUartPort(vm name: String) async throws {
		try refuseWhileHosted(name, "changing its serial ports")
		try await local.addUartPort(vm: name)
	}

	public func removeUartPort(vm name: String) async throws {
		try refuseWhileHosted(name, "changing its serial ports")
		try await local.removeUartPort(vm: name)
	}

	public func setSerialLogging(
		vm name: String, kind: SerialPortKind, index: Int, config: SerialLogConfig
	) async throws {
		try await target(name).setSerialLogging(vm: name, kind: kind, index: index, config: config)
	}

	public func setKernelBoot(vm name: String, enabled: Bool) async throws {
		try await target(name).setKernelBoot(vm: name, enabled: enabled)
	}

	public func updateKernelSettings(vm name: String, _ settings: KernelSettings) async throws {
		try await target(name).updateKernelSettings(vm: name, settings)
	}

	public func promoteKernelFile(
		vm name: String, role: KernelRole, sourcePath: String, tag: String
	) async throws -> VMInfo {
		try await target(name).promoteKernelFile(
			vm: name, role: role, sourcePath: sourcePath, tag: tag)
	}

	public func deleteKernelFile(vm name: String, path: String) async throws -> VMInfo {
		try await target(name).deleteKernelFile(vm: name, path: path)
	}

	public func setStartPolicy(vm name: String, policy: StartPolicy) async throws {
		// Policy has a daemon-side launchd side effect that must never reconcile against a
		// discardable shadow write — refuse rather than half-apply.
		if let host = hosted[name], host.identity.isSafe {
			throw MachmanError(
				code: .invalidState,
				message: "run defaults cannot change during a safe run — stop \(name) "
					+ "or save it first")
		}
		try await target(name).setStartPolicy(vm: name, policy: policy)
		// Agent bookkeeping reads the ARGUMENT, never the registry: while the VM is hosted
		// the daemon's config copy is stale until the host exits.
		guard let launchAgents else { return }
		if policy.autostart {
			do {
				try launchAgents.install(vm: name)
			} catch {
				MachmanLogger.log(.passiveError,
					"cannot write launch agent for \(name): \(error)")
			}
		} else {
			launchAgents.remove(vm: name, canBootout: hosted[name] == nil)
		}
	}

	public func setSafety(
		vm name: String, disks: [String: Bool]?, mounts: [String: Bool]?
	) async throws {
		try await target(name).setSafety(vm: name, disks: disks, mounts: mounts)
	}

	// MARK: - Guest devices (1.0.4) — config-plane edits proxy like disks (next-boot effect).

	public func addDevice(vm name: String, kind: DeviceKind) async throws -> VMInfo {
		try await target(name).addDevice(vm: name, kind: kind)
	}

	public func removeDevice(vm name: String, kind: DeviceKind) async throws -> VMInfo {
		try await target(name).removeDevice(vm: name, kind: kind)
	}

	public func updateDevice(vm name: String, device: DeviceInfo) async throws -> VMInfo {
		try await target(name).updateDevice(vm: name, device: device)
	}

	public func setEnabled(
		vm name: String, disks: [String: Bool]?, mounts: [String: Bool]?,
		console: [String: Bool]?, uart: [String: Bool]?
	) async throws {
		try await target(name).setEnabled(
			vm: name, disks: disks, mounts: mounts, console: console, uart: uart)
	}

	public func setKernelOverride(
		vm name: String, path: String, commandLine: String?, overrideEnabled: Bool?
	) async throws -> VMInfo {
		try await target(name).setKernelOverride(
			vm: name, path: path, commandLine: commandLine, overrideEnabled: overrideEnabled)
	}

	public func resizeDisk(vm name: String, diskID: String, sizeBytes: UInt64) async throws
		-> VMInfo {
		// Growing the raw file under a live VZ attachment is unsafe — stop first.
		try refuseWhileHosted(name, "resizing its disks")
		return try await local.resizeDisk(vm: name, diskID: diskID, sizeBytes: sizeBytes)
	}
	public func renameDisk(vm name: String, diskID: String, newName: String) async throws
		-> VMInfo {
		// Moving the raw file under a live VZ attachment is unsafe — stop first.
		try refuseWhileHosted(name, "renaming its disks")
		return try await local.renameDisk(vm: name, diskID: diskID, newName: newName)
	}
	public func setMountTag(vm name: String, mountID: String, tag: String) async throws
		-> VMInfo {
		// Next-boot effect: safe to record on a hosted VM, like other mount edits.
		try await target(name).setMountTag(vm: name, mountID: mountID, tag: tag)
	}
	public func setMountKind(vm name: String, mountID: String, kind: String) async throws
		-> VMInfo {
		// Next-boot effect: safe to record on a hosted VM, like other mount edits.
		try await target(name).setMountKind(vm: name, mountID: mountID, kind: kind)
	}
	public func renameKernelFile(vm name: String, path: String, tag: String) async throws
		-> VMInfo {
		// The hosted VM's config references the old path — stop first.
		try refuseWhileHosted(name, "renaming its kernel files")
		return try await local.renameKernelFile(vm: name, path: path, tag: tag)
	}

	// MARK: - SSH (1.0.5)

	// Config-plane like devices, but with daemon-side ~/.ssh effects — refuse during safe
	// runs (setStartPolicy reasoning: host-side state must never reconcile against a
	// discardable shadow write).
	private func refuseSSHWhileSafe(_ name: String) throws {
		if let host = hosted[name], host.identity.isSafe {
			throw MachmanError(
				code: .invalidState,
				message: "SSH settings cannot change during a safe run — stop \(name) "
					+ "or save it first")
		}
	}

	public func setSSH(
		vm name: String, integrationEnabled: Bool?, reverseApproved: Bool?, alias: String?
	) async throws -> VMInfo {
		try refuseSSHWhileSafe(name)
		// Uniqueness is checkable only here: a vmhost sees exactly one VM, and two VMs
		// sharing a Host name would make `ssh <alias>` reach whichever block came first.
		if let alias {
			let wanted = alias.trimmingCharacters(in: .whitespaces)
			if !wanted.isEmpty {
				for other in registry.list() where other.name != name {
					guard other.config.effectiveSSHAlias == wanted else { continue }
					throw MachmanError(
						code: .invalidArgument,
						message: "\(other.name) already answers to \"\(wanted)\"")
				}
			}
		}
		let info = try await target(name).setSSH(
			vm: name, integrationEnabled: integrationEnabled,
			reverseApproved: reverseApproved, alias: alias)
		// Host-side effects AFTER the config write succeeded, from the RETURNED state —
		// the daemon's registry copy is stale while the VM is hosted (setStartPolicy
		// precedent). Approving with no key is refused engine-side, so the force-unwrap
		// shape never arises here.
		if let writer = sshHostConfig, let reverseApproved,
			let marker = existingSSHMarker(name) {
			try? writer.setReverseKey(
				reverseApproved ? info.ssh?.reversePublicKey : nil,
				marker: marker, vmName: name)
		}
		scheduleSSHHostConfigWrite()
		return info
	}

	public func refreshSSH(vm name: String) async throws {
		guard let host = hosted[name] else {
			throw MachmanError(
				code: .invalidState, message: "\(name) is not running — nothing to discover")
		}
		host.sshAnswer = nil
		startSSHDiscovery(host)
	}

	public func resetSSH(vm name: String) async throws -> VMInfo {
		try refuseSSHWhileSafe(name)
		let marker = existingSSHMarker(name)
		let info = try await target(name).resetSSH(vm: name)
		if let writer = sshHostConfig, let marker {
			try? writer.setReverseKey(nil, marker: marker, vmName: name)
		}
		scheduleSSHHostConfigWrite()
		return info
	}

	// MARK: - Guest setup (1.0.7)

	public func resetSetup(vm name: String) async throws -> VMInfo {
		// Config-plane only (no daemon-side effects) — plain proxy, like device edits.
		try await target(name).resetSetup(vm: name)
	}

	public func setSetupServed(vm name: String, serve: Bool) async throws -> VMInfo {
		// Routed to the vmhost while running: it owns the config there AND does the
		// live fill when serving turns on.
		try await target(name).setSetupServed(vm: name, serve: serve)
	}

	// The marker labeling this VM's host-side artifacts — a read-only derivation from
	// the identity file, safe against the stale-while-hosted registry copy (paths only).
	private func existingSSHMarker(_ name: String) -> String? {
		guard let config = registry.vm(named: name)?.config else { return nil }
		return SSHSetupInstaller.existingMarker(for: config)
	}

	// Rebuild ~/.ssh/machman/config (+ Include line) from current state. Fire-and-forget
	// with whole-state writes — concurrent triggers converge on last-write-wins.
	private func scheduleSSHHostConfigWrite() {
		guard sshHostConfig != nil else { return }
		Task { [weak self] in
			await self?.writeSSHHostConfig()
		}
	}

	private func writeSSHHostConfig() async {
		guard let writer = sshHostConfig else { return }
		var entries: [SSHHostConfigWriter.VMEntry] = []
		for vm in registry.list() {
			let name = vm.name
			var info: VMInfo?
			if let host = hosted[name], !host.identity.isSafe {
				// The vmhost's answer is the fresh state; the registry copy is stale.
				info = try? await host.client.vm(named: name)
				if var overlaid = info {
					overlaySSH(&overlaid, from: host)
					info = overlaid
				}
			} else {
				// Stopped — or SAFE-hosted: a shadow's ssh state (its report, its
				// address) is temporary by definition and must never persist into
				// ~/.ssh. The daemon's copy of the REAL config is current here — the
				// safe vmhost only ever writes the shadow.
				info = try? await local.vm(named: name)
			}
			guard let ssh = info?.ssh, ssh.integrationEnabled == true else { continue }
			entries.append(SSHHostConfigWriter.VMEntry(
				name: name,
				alias: ssh.alias ?? SSHHostConfigWriter.defaultAlias(for: name),
				user: ssh.guestUser,
				// Discovery first, then what the guest last reported: without the
				// fallback a rename (or an alias change) strands a stopped VM's entry,
				// because the managed file itself was the only memory of the address.
				address: ssh.address ?? vm.config.ssh?.lastAddress,
				identityFilePath: ssh.identityFilePath, hostKey: ssh.guestHostKey))
		}
		do {
			try writer.apply(entries: entries)
		} catch {
			MachmanLogger.log(.passiveError, "cannot write ~/.ssh/machman/config: \(error)")
		}
	}

	// MARK: - Operations (1.0.4)

	// The daemon's own operations plus every hosted VM's (imports on a running VM execute
	// in its vmhost, which runs its own OperationCenter).
	public func operations() async throws -> [OperationInfo] {
		var all = try await local.operations()
		for host in hosted.values {
			if let ops = try? await host.client.operations() {
				all.append(contentsOf: ops)
			}
		}
		return all.sorted { $0.startedAt < $1.startedAt }
	}

	public func cancelOperation(id: String) async throws {
		do {
			try await local.cancelOperation(id: id)
			return
		} catch let error as MachmanError where error.code == .notFound {
			// Not a daemon-side operation — try the vmhosts.
		}
		for host in hosted.values {
			do {
				try await host.client.cancelOperation(id: id)
				return
			} catch let error as MachmanError where error.code == .notFound {
				continue
			}
		}
		throw MachmanError(code: .notFound, message: "no operation '\(id)'")
	}

	// System-prompted Rosetta install, tracked as an indeterminate operation. Returns
	// immediately; the operation reaches its terminal state when the system flow completes
	// (clients re-fetch host.capabilities on success). macOS 27 makes this an instant no-op.
	public func installRosetta() async throws {
		switch VZLinuxRosettaDirectoryShare.availability {
		case .installed:
			return   // already there — success
		case .notSupported:
			throw MachmanError(
				code: .invalidState, message: "Rosetta is not supported on this host")
		case .notInstalled:
			break
		@unknown default:
			throw MachmanError(
				code: .invalidState, message: "Rosetta availability is unknown on this host")
		}
		let center = local.operationCenter
		let opID = center.begin(
			kind: OperationInfo.Kind.rosettaInstall, label: "Installing Rosetta")
		VZLinuxRosettaDirectoryShare.installRosetta { error in
			Task { @MainActor in
				if let error {
					center.finish(
						opID, state: OperationInfo.State.failed,
						message: error.localizedDescription)
				} else {
					center.finish(opID, state: OperationInfo.State.succeeded)
				}
			}
		}
	}

	public func start(vm name: String, options: StartOptions) async throws {
		guard hosted[name] == nil else {
			throw MachmanError(code: .invalidState, message: "\(name) is already running")
		}
		guard !pendingStarts.contains(name) else {
			throw MachmanError(code: .invalidState, message: "\(name) is already starting")
		}
		guard let vm = registry.vm(named: name) else {
			throw MachmanError.notFound(name)
		}
		guard !registry.isInstalling(vm) else {
			throw MachmanError(
				code: .invalidState,
				message: "(\(name)) cannot start while macOS is installing")
		}
		// Reserved before the first await; the defer releases on every exit, success or
		// throw. Everything below (probe, spawn, shadow build) runs under this claim.
		pendingStarts.insert(name)
		defer { pendingStarts.remove(name) }
		purgeDeadShadows(for: name)
		// A live vmhost may already own this VM's socket — launchd autostart, or a spawn
		// whose daemon died before forwarding start. Adopt it instead of racing it with a
		// second host. Deliberately ahead of the MAC-conflict guard: an already-running VM
		// is a fact, not a request — refusing to adopt it would strand it.
		let socketPath = Self.hostSocketPath(for: name)
		if FileManager.default.fileExists(atPath: socketPath),
			try await probeAdoptAndStart(name: name, socketPath: socketPath, options: options) {
			return
		}
		// The router is the only place that sees every host's live MAC. Applies to safe runs
		// too — the shadow impersonates this VM's MAC.
		if !options.force, let mac = vm.config.macAddress,
			let clash = hosted.values.first(where: { $0.identity.macInUse == mac }) {
			throw MachmanError(
				code: .macConflict,
				message: "\(name) uses MAC \(mac), which running VM "
					+ "'\(clash.identity.name)' is already using — one of them would lose "
					+ "networking. Stop it, regenerate a MAC, or force start.")
		}
		if options.safe {
			try await startSafe(vm: vm, name: name, options: options)
			return
		}
		let identity = HostIdentity(
			id: UUID(), name: name, socketPath: Self.hostSocketPath(for: name),
			macInUse: vm.config.macAddress)
		let host = try await spawnHost(identity: identity, dataDir: machmanVMDir)
		do {
			try await host.client.start(vm: name, options: options)
		} catch {
			host.deathWatch?.invalidate()
			host.deathWatch = nil
			host.app?.forceTerminate()
			await host.client.disconnect()
			unlink(host.identity.socketPath)
			throw error
		}
		hosted[name] = host
		subscribeEvents(host)
		// Explicit kick, not the event filter: the vmhost emitted .running while start()
		// was still in flight — BEFORE this subscription existed — so a fresh start would
		// otherwise never discover (the filter still covers guest reboots).
		startSSHDiscovery(host)
		registry.events.emit(.listChanged)
	}

	// A safe run: clone the VM into a shadow run root (per-disk/mount safe flags decide
	// clone-vs-reference / omit-vs-attach), run the vmhost against the shadow, and present
	// it AS the real VM. --library is passed ONLY here: it is the promotion destination and
	// its absence makes a vmhost refuse safeSave (the misattribution backstop).
	private func startSafe(vm: VirtualMachine, name: String, options: StartOptions) async throws {
		let runRoot = machmanSafeDir + "/" + SafeRun.runPrefix + UUID().uuidString
		do {
			try FileManager.default.createDirectory(
				atPath: runRoot, withIntermediateDirectories: true)
			// Phase-1 marker: intent, no pid yet — the sweep treats it as never-attachable.
			try SafeRun.writeMarker(
				ShadowMarker(vm: name, createdAt: Date(), pid: nil), runRoot: runRoot)
			let events = registry.events
			let center = local.operationCenter
			let opID = center.begin(
				kind: OperationInfo.Kind.shadowBuild, vm: name,
				label: "Preparing safe run of \(name)")
			let request = SafeRun.shadowRequest(
				config: vm.config, sourceDir: machmanVMDir + "/" + name, runRoot: runRoot,
				progress: { copied, total in
					Task { @MainActor in
						events.emit(.copyProgress(
							vm: name, copiedBytes: copied, totalBytes: total))
						center.update(
							opID, fraction: total > 0 ? Double(copied) / Double(total) : nil,
							completedBytes: Int64(copied), totalBytes: Int64(total))
					}
				})
			// Detached: same-volume clones are instant, but unsafe-marked-safe external
			// images can be real byte copies.
			do {
				try await Task.detached(priority: .userInitiated) {
					try VMCopier.copy(request)
				}.value
			} catch {
				center.finish(
					opID, state: OperationInfo.State.failed, message: "\(error)")
				throw error
			}
			center.finish(opID, state: OperationInfo.State.succeeded)
		} catch {
			try? FileManager.default.removeItem(atPath: runRoot)
			throw error
		}
		var identity = HostIdentity(
			id: UUID(), name: name, socketPath: Self.hostSocketPath(for: name),
			macInUse: vm.config.macAddress)
		identity.isSafe = true
		identity.shadowRoot = runRoot
		let host: HostedVM
		do {
			host = try await spawnHost(
				identity: identity, dataDir: runRoot,
				extraArguments: ["--library", machmanVMDir])
			// Phase-2 marker: the pid the startup sweep matches against the socket peer.
			try? SafeRun.writeMarker(
				ShadowMarker(
					vm: name, createdAt: Date(), pid: host.app?.processIdentifier),
				runRoot: runRoot)
		} catch {
			try? FileManager.default.removeItem(atPath: runRoot)
			throw error
		}
		var forwarded = options
		forwarded.safe = false   // the vmhost never knows it runs a shadow
		do {
			try await host.client.start(vm: name, options: forwarded)
		} catch {
			host.deathWatch?.invalidate()
			host.deathWatch = nil
			host.app?.forceTerminate()
			await host.client.disconnect()
			unlink(host.identity.socketPath)
			try? FileManager.default.removeItem(atPath: runRoot)
			throw error
		}
		hosted[name] = host
		subscribeEvents(host)
		// Same missed-running reasoning as the plain start path; the shadow impersonates
		// the VM's MAC, so discovery works for safe runs too.
		startSSHDiscovery(host)
		registry.events.emit(.listChanged)
	}

	// Internal seam (tests inject their own socket path): probe a socket that exists, adopt
	// whoever answers, and forward the start. Returns false when the socket was a dead
	// leftover — reclaimed, caller falls through to a fresh spawn.
	func probeAdoptAndStart(
		name: String, socketPath: String, options: StartOptions
	) async throws -> Bool {
		var identity = HostIdentity(
			id: UUID(), name: name, socketPath: socketPath,
			macInUse: registry.vm(named: name)?.config.macAddress)
		guard let client = try? await connectHost(identity: identity) else {
			guard !UDSListener.isLive(path: socketPath) else {
				// NEVER unlink a live socket (single-writer rule) — whoever owns it may
				// recover; spawning over it would fork the VM's identity.
				throw MachmanError(
					code: .internalError,
					message: "a vmhost owns \(name)'s socket but did not answer")
			}
			unlink(socketPath)
			return false
		}
		// The adopt-side rule: the host's reply is the authoritative live MAC.
		identity.macInUse = (try? await client.vm(named: name))?.macAddress ?? identity.macInUse
		adopt(identity: identity, client: client)
		var forwarded = options
		if options.safe {
			// An existing run cannot be made safe retroactively — adopt it as it is.
			MachmanLogger.log(.passiveWarning,
				"safe start requested for \(name), but a live vmhost already owns it")
			forwarded.safe = false
		}
		do {
			try await client.start(vm: name, options: forwarded)
		} catch let error as MachmanError where error.code == .invalidState {
			// Already running (autostart got there first) — the caller still gets what
			// they asked for.
			if options.openWindow {
				try? await client.openWindow(vm: name)
			}
		}
		// Other start failures propagate with the host still adopted: it is live and owns
		// the VM; its own lifecycle (or the user) cleans up.
		return true
	}

	// Launch agents rot when nobody is looking: DerivedData moves change the vmhost path,
	// deleted VMs can leave a plist behind after a crash. Rewrite what every autostart VM
	// needs and sweep the rest. Runs at daemon startup after adoption.
	public func healLaunchAgents() {
		guard let launchAgents else { return }
		var wanted: Set<String> = []
		for vm in registry.list() where vm.config.startPolicy.autostart {
			wanted.insert(launchAgents.plistFileName(for: vm.name))
			do {
				if try launchAgents.installIfChanged(vm: vm.name) {
					MachmanLogger.log(.log, "rewrote launch agent for \(vm.name)")
				}
			} catch {
				MachmanLogger.log(.passiveError,
					"cannot heal launch agent for \(vm.name): \(error)")
			}
		}
		let prefix = launchAgents.suiteID + ".vm."
		let entries = (try? FileManager.default.contentsOfDirectory(
			atPath: launchAgents.agentsDir)) ?? []
		for entry in entries
			where entry.hasPrefix(prefix) && entry.hasSuffix(".plist")
				&& !wanted.contains(entry) {
			// File only, no bootout: a loaded stale job dies at next login, and a VM it is
			// still running keeps its host either way.
			try? FileManager.default.removeItem(atPath: launchAgents.agentsDir + "/" + entry)
			MachmanLogger.log(.log, "swept stale launch agent \(entry)")
		}
	}

	public func stop(vm name: String, mode: StopMode) async throws {
		try await target(name).stop(vm: name, mode: mode)
	}

	public func openWindow(vm name: String) async throws {
		try await target(name).openWindow(vm: name)
	}

	public func closeWindow(vm name: String) async throws {
		try await target(name).closeWindow(vm: name)
	}

	public func preview(vm name: String, maxWidth: Int?) async throws -> Data? {
		try await target(name).preview(vm: name, maxWidth: maxWidth)
	}

	public func startMacInstall(vm name: String, source: InstallSource) async throws {
		try refuseWhileHosted(name, "installing macOS")
		try await local.startMacInstall(vm: name, source: source)
	}

	public func cancelMacInstall(vm name: String) async throws {
		try await local.cancelMacInstall(vm: name)
	}

	public func macInstallPhase(vm name: String) async throws -> InstallPhase {
		try await local.macInstallPhase(vm: name)
	}

	public func safeSave(vm name: String, to newName: String) async throws -> VMInfo {
		guard let host = hosted[name], host.identity.isSafe else {
			throw MachmanError(
				code: .invalidState, message: "\(name) is not running in safe mode")
		}
		guard registry.vm(named: newName) == nil, hosted[newName] == nil else {
			throw MachmanError(
				code: .alreadyExists, message: "a VM named '\(newName)' already exists")
		}
		// The vmhost moves the files (single writer); the daemon re-keys its view after.
		let info = try await host.client.safeSave(vm: name, to: newName)
		// ONE synchronous block: the host keeps its socket (stored path — the 1.2 rule) and
		// its live MAC. Keeping macInUse is deliberate: starting the ORIGINAL now trips
		// macConflict until the promoted VM reboots onto its fresh MAC.
		host.identity.name = newName
		host.identity.isSafe = false
		host.identity.shadowRoot = nil   // the vmhost moved + deleted the run root itself
		hosted[name] = nil
		hosted[newName] = host
		do {
			_ = try registry.adoptFromDisk(name: newName)
		} catch {
			// The host is live and keyed either way; the next listChanged/reload catches up.
			MachmanLogger.log(.passiveError,
				"promoted \(newName) is live but not yet adoptable: \(error)")
		}
		registry.events.emit(.stateChanged(vm: name, state: .stopped))
		registry.events.emit(.stateChanged(vm: newName, state: .running))
		registry.events.emit(.listChanged)
		return info
	}

	// Wired by the daemon app: stop serving and exit leave-VMs-running. The reply flushes
	// first — the handler only schedules the shutdown.
	public var onRetire: (() -> Void)?

	public func retire() async throws {
		guard let onRetire else {
			throw MachmanError(code: .invalidState, message: "this process cannot retire")
		}
		MachmanLogger.log(.log, "retiring on request; vmhosts keep running")
		Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(200))   // let the reply flush
			onRetire()
		}
	}

	public func events() async -> AsyncStream<VMEvent> {
		registry.events.stream()
	}
}
