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
	// The shadow build's progress label; its card reads "<VM> — Preparing a safe run".
	nonisolated static let safeRunLabel = "Preparing a safe run"

	let registry: VMRegistry
	let local: LocalMachman
	let daemonVersion: String
	// Injected (not built here) so unit tests can never touch ~/Library/LaunchAgents by
	// construction. nil = no agents are written; policy toggles still persist.
	let launchAgents: LaunchAgentManager?
	// Same rule for ~/.ssh: injected by the daemon, nil in tests — SSH switches still
	// persist, only the host-side files stay untouched.
	let sshHostConfig: SSHHostConfigWriter?

	var hosted: [String: HostedVM] = [:]   // keyed by VM name

	// The start-window reservation. `hosted[name]` is written only after the NSWorkspace
	// launch, the connect poll, and (for safe runs) a possibly minutes-long shadow build —
	// so a guard that reads only `hosted` has a window where a booting VM looks idle: a
	// second start would adopt-then-kill the half-spawned host, a delete would remove the
	// directory under it, and a concurrent purgeDeadShadows would eat the in-flight shadow
	// build. A name lives in here from start()'s first line until the start completed or
	// failed; main-actor confinement makes the check-then-insert atomic. Internal (not
	// private) as a test seam — tests reserve a name to exercise the guards.
	var pendingStarts: Set<String> = []
	// The MAC each in-flight start will boot with, and the order the starts reserved in:
	// the MAC-conflict check counts starts still in their spawn window, and the earlier
	// reservation wins. Internal read for tests.
	private(set) var pendingStartMACs: [String: (order: Int, mac: String)] = [:]
	private var nextStartOrder = 0

	// Claims the name (and its MAC) for a start; internal so tests can stage a start in flight.
	func reserveStart(_ name: String, mac: String?) {
		pendingStarts.insert(name)
		if let mac {
			pendingStartMACs[name] = (nextStartOrder, mac)
		}
		nextStartOrder += 1
	}

	func releaseStart(_ name: String) {
		pendingStarts.remove(name)
		pendingStartMACs[name] = nil
	}

	// E20: how long one vmhost may take to answer a list, get, operations or preview probe
	// before its VM is served from its last answer, marked unresponsive; and how often a
	// marked host is asked again. Internal seams for tests.
	var hostProbeDeadline: Duration = .seconds(3)
	var recoveryInterval: Duration = .seconds(2)
	var helloDeadline: Duration = .seconds(10)
	// How long a start waits for a host that is exiting after its VM stopped (E12).
	var hostExitGrace: Duration = .seconds(3)
	// Whether a vmhost process still exists (E8). A seam: an in-process test host's peer is
	// the test itself, so a test that ends a host says so here.
	var isProcessAlive: (Int32) -> Bool = SafeRun.defaultPidAlive
	// Ends an idle vmhost that runs older code than this daemon, before a start spawns a
	// current one (R3-3). It runs no VM, so a kill loses nothing. False when it could not:
	// no app and no peer pid to end it by (RR3-3). A seam for the same reason as
	// isProcessAlive: an in-process test host's peer is the test.
	var endIdleHost: (HostedVM) -> Bool = { host in
		if let app = host.app {
			return app.forceTerminate() || app.isTerminated
		}
		guard let pid = host.client.peerPID else { return false }
		return kill(pid, SIGKILL) == 0 || errno == ESRCH
	}

	// Late adoption (E21): one in-flight adoption per name, shared by every caller, and the
	// names whose live vmhost did not answer the last attempt (listed as not responding
	// until one gets through).
	var adoptions: [String: Task<HostedVM, Error>] = [:]
	var unadoptable: Set<String> = []
	var adoptionAttempts = 0   // test seam: connects made to adopt a host

	// Where the vmhost app lives. Internal test seam: a test that reaches spawnHost pins this
	// to nil, so it fails at "not found" on every machine instead of depending on where the
	// test binary happens to sit (a located MachmanVMHost.app would be LAUNCHED).
	var locateVMHost: () -> VMHostLocation? = { VMHostLocator.locate() }

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

	// Adopt vmhosts left behind by an earlier daemon: a live host answers on its socket and
	// keeps running (its VM never noticed the daemon restart); a stale socket is reclaimed.
	// This is the daemon's whole startup reconciliation, so it also has to cope with the
	// ungraceful cases — force quit, crash, power loss — where nothing got to clean up.
	public func adoptExistingHosts() async {
		pruneDeadHostSockets()
		for vm in registry.list() {
			let name = vm.name
			guard hosted[name] == nil else { continue }
			let socketPath = hostSocketPath(for: name)
			guard FileManager.default.fileExists(atPath: socketPath),
				hostHolding(socketPath) == nil else { continue }
			do {
				let host = try await adoptLiveHost(name)
				MachmanLogger.log(.log, "adopted running vmhost for \(host.identity.name)")
			} catch {
				// NEVER unlink a live socket (single-writer rule, probe-adopt's guard): a
				// vmhost whose main actor is busy misses hello but still owns the VM.
				// Without its socket it turned invisible and unstoppable, and the next start
				// spawned a second VZ against the same disks (E21).
				guard !UDSListener.isLive(path: socketPath) else {
					MachmanLogger.log(.passiveWarning,
						"kept \(name)'s live vmhost socket (\(error)) — adopting it on next use")
					continue
				}
				unlink(socketPath)
			}
		}
	}

	// A late adoption's half of the startup sweep: the run root whose marker names this VM
	// and this host's pid makes the host a safe run again. Never deletes — a pid-nil root
	// may be an in-flight safe start's shadow build; the startup sweep decides the rest.
	func reattachSafeRun(_ host: HostedVM, safeDir: String = machmanSafeDir) {
		guard let peer = host.client.peerPID,
			let entries = try? FileManager.default.contentsOfDirectory(atPath: safeDir)
		else { return }
		for entry in entries.sorted() where entry.hasPrefix(SafeRun.runPrefix) {
			let runRoot = safeDir + "/" + entry
			guard let marker = SafeRun.readMarker(runRoot: runRoot),
				marker.vm == host.identity.name, marker.pid == peer else { continue }
			host.identity.isSafe = true
			host.identity.shadowRoot = runRoot
			MachmanLogger.log(.log, "re-attached safe run \(entry) to \(marker.vm)")
			return
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
				guard let marker, let host = hosted[marker.vm],
					host.identity.shadowRoot != runRoot else { break }   // adoption did
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

	// Runs at daemon startup, after adoptExistingHosts: a VM that loses an older ssh alias
	// collision (A-1a-1) and is served its suffix by resolution alone stores it now, so the
	// winner's delete or rename can't hand it the base before its own next save. Only VMs
	// nothing hosts — a vmhost owns its VM's config, and stores the suffix on its next save.
	public func storeCollisionAliases() {
		storeCollisionAliases(isSocketLive: { UDSListener.isLive(path: $0) })
	}

	func storeCollisionAliases(isSocketLive: (String) -> Bool) {
		for vm in registry.list() where hosted[vm.name] == nil {
			let config = vm.config
			guard config.ssh?.alias == nil,
				config.resolvedDefaultAlias != SSHHostConfigWriter.defaultAlias(for: vm.name),
				!isSocketLive(hostSocketPath(for: vm.name)) else { continue }
			do {
				try config.saveVMConfig()   // every save stores a resolved suffix
				MachmanLogger.log(.log,
					"stored \(vm.name)'s ssh alias \(config.ssh?.alias ?? "?") (older collision)")
			} catch {
				MachmanLogger.log(.passiveWarning,
					"could not store \(vm.name)'s ssh alias: \(error)")
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
			guard !isSocketLive(hostSocketPath(for: vm.name)) else { continue }
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

	// MARK: - Host plumbing

	// Where a VM's vmhost serves. A test seam: the test runtime dir already sits at sun_path's
	// 104-byte limit, so routing tests point this into their scratch dir.
	var socketPathForVM: (String) -> String = { machmanVMSocketPath(vm: $0) }

	func hostSocketPath(for name: String) -> String {
		socketPathForVM(name)
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

	// MARK: - SSH discovery (1.0.5, daemon-side)

	// Host-side access follows the CURRENT key, always. A guest that re-runs the setup
	// script after an uninstall mints a fresh reverse key, which drops approval back to
	// pending — and the line installed for the old key has to go with it, or that key
	// keeps its way in with nothing in the UI offering to revoke it.
	func reconcileReverseKey(vm name: String) {
		guard let writer = sshHostConfig, let marker = existingSSHMarker(name) else { return }
		Task { [weak self] in
			guard let self,
				let ssh = (try? await self.proxy(name).vm(named: name))?.ssh else { return }
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
	func startSSHDiscovery(_ host: HostedVM) {
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

	// Who owns a VM's files right now — the ONE table every per-VM entry point reads (PR1),
	// so no call can slip through a window another one guards:
	//   starting   a start is in flight (spawn window, safe-run shadow build). It owns the
	//              name even once a host is registered: the vmhost is (or is about to be)
	//              reading the very config files, and its whole-file saves would silently
	//              revert any daemon-side edit (E19).
	//   hosted     a vmhost this daemon spawned or adopted serves the VM.
	//   unadopted  a vmhost answers on the VM's socket that the hosted map has never heard of
	//              (a launch-agent start, a socket that appeared after adoption ran). The
	//              socket is the truth, not the map.
	//   local      stopped: the daemon's own engine owns the config.
	enum Residence {
		case starting
		case hosted(HostedVM)
		case unadopted
		case local
	}

	func residence(of name: String) -> Residence {
		if pendingStarts.contains(name) { return .starting }
		if let host = hosted[name] { return .hosted(host) }
		let path = hostSocketPath(for: name)
		// E27: a run saved as a new VM by an older vmhost keeps its original's socket — a
		// path another hosted VM holds is not this VM's.
		if hostHolding(path) != nil { return .local }
		if UDSListener.isLive(path: path) { return .unadopted }
		return .local
	}

	func hostHolding(_ path: String) -> HostedVM? {
		hosted.values.first { $0.identity.socketPath == path }
	}

	// Config/window-plane routing: the process that owns the VM's config — its vmhost while
	// one runs it, else the daemon-local engine. Never the daemon's copy while a start or an
	// unadopted vmhost owns the files: those edits were silently reverted, and a vm.stop
	// "succeeded" doing nothing.
	func proxy(_ name: String) async throws -> MachmanControlling {
		switch residence(of: name) {
		case .hosted(let host):
			return host.client
		case .starting:
			throw MachmanError(
				code: .invalidState,
				message: "\(name) is starting — try again once it is running")
		case .unadopted:
			do {
				let host = try await adoptLiveHost(name)
				// E27: it serves another VM; the residence now says who owns this one.
				guard host.identity.name == name else { return try await proxy(name) }
				return host.client
			} catch {
				throw MachmanError(
					code: .invalidState,
					message: "\(name) is not responding — try again in a moment")
			}
		case .local:
			return local
		}
	}

	// E22 (decision 9): a vmhost older than this daemon runs old code — its decoder drops
	// config keys this daemon's clients rely on. Its VM keeps running, stops and opens its
	// window as before, but its setting changes are refused until it restarts under a
	// current vmhost. The floor is this daemon's own version (the version pair moves only
	// for changes an old+new mix can't take). A vmhost that reports no usable version counts
	// as older; a daemon without one of its own (tests, an unversioned build) has no floor.
	func isOutdated(_ host: HostedVM) -> Bool {
		MachmanVersion.isOlder(host.version, than: daemonVersion)
	}

	// The owner of a setting change: proxy()'s, refused while it is an outdated vmhost.
	func settingsOwner(_ name: String) async throws -> MachmanControlling {
		let target = try await proxy(name)
		if let host = hosted[name], isOutdated(host) {
			throw MachmanError(
				code: .invalidState, message: "Restart \(name) to finish updating")
		}
		return target
	}

	// Whole-VM edits the framework fixes at start (files moved, ports, MAC) refuse rather
	// than proxy unless the VM is stopped — and stopped means no start in flight and no
	// vmhost answering on its socket either, whether this daemon adopted it or not.
	func requireStopped(_ name: String, _ action: String) throws {
		switch residence(of: name) {
		case .hosted:
			throw MachmanError(code: .invalidState, message: "Stop \(name) before \(action)")
		case .starting:
			throw MachmanError(
				code: .invalidState, message: "\(name) is starting — wait before \(action)")
		case .unadopted:
			throw MachmanError(
				code: .invalidState,
				message: "\(name) is still running — stop it before \(action)")
		case .local:
			return
		}
	}

	// MARK: - MachmanControlling

	public func hostCapabilities() async throws -> HostCapabilities {
		try await local.hostCapabilities()
	}

	// Every hosted VM is asked at once, each bounded by hostProbeDeadline: a stalled vmhost
	// costs the list one deadline, never the whole call for every client (E20). The probes
	// are main-actor Tasks that suspend inside the RPC, so they overlap.
	public func listVMs() async throws -> [VMInfo] {
		let vms = registry.list()
		var probes: [String: (host: HostedVM, answer: Task<ProbeResult, Never>)] = [:]
		for vm in vms {
			guard let host = hosted[vm.name] else { continue }
			probes[vm.name] = (host, Task { await self.probe(host) })
		}
		var infos: [VMInfo] = []
		for vm in vms {
			if let probed = probes[vm.name] {
				let result = await probed.answer.value
				// A host gone or re-keyed during the wait (a stop, safe-save) answered for a
				// run that is over: fall through to what owns the VM now.
				if hosted[vm.name] === probed.host {
					infos.append(try await presented(probed.host, result))
					continue
				}
			}
			infos.append(try await self.vm(named: vm.name))
		}
		return infos
	}

	public func vm(named name: String) async throws -> VMInfo {
		if let host = hosted[name] {
			let result = await probe(host)
			if hosted[name] === host {
				return try await presented(host, result)
			}
		}
		return try await localInfo(name)
	}

	// The daemon's own view of a VM nothing hosted answers for. During a start's spawn
	// window it says starting, never stopped: a stopped VM offered a second Start.
	// An unadopted vmhost's VM is adopted in the background; until then the daemon's copy
	// knows nothing of the run, so its state is unknown (not stopped), and not responding
	// once an adoption failed.
	private func localInfo(_ name: String) async throws -> VMInfo {
		var info = try await local.vm(named: name)
		switch residence(of: name) {
		case .starting:
			info.state = .starting
		case .unadopted:
			scheduleAdoption(name)
			info.state = .unknown
			if unadoptable.contains(name) { info.unresponsive = true }
		case .local:
			unadoptable.remove(name)
		case .hosted:
			break
		}
		return info
	}

	// A hosted VM as clients see it, with the daemon-side overlays (only the router knows a
	// run is safe, and only it runs address discovery). Without an answer: the host's last
	// one, or the daemon's config copy with state unknown when it never answered — marked
	// unresponsive while it misses its deadline. Never "stopped": clients would report a
	// stop that never happened.
	private func presented(_ host: HostedVM, _ result: ProbeResult) async throws -> VMInfo {
		var info: VMInfo
		if case .answered(let answer) = result {
			info = answer
		} else if let last = host.lastAnswer {
			info = last
		} else {
			info = try await local.vm(named: host.identity.name)
			info.state = .unknown
		}
		info.unresponsive = host.unresponsive ? true : nil
		info.outdatedHost = isOutdated(host) ? true : nil
		if host.identity.isSafe { info.safeRun = true }
		overlaySSH(&info, from: host)
		return info
	}

	// The discovered address rides every VMInfo answer while the VM is hosted — attached
	// to the served ssh state, or as a minimal shell when the guest never reported.
	// The daemon's half of SSHInfo: what discovery found, and how this run is going.
	// Nothing is invented for a VM that never used SSH and has no address either — the
	// clients read a nil `ssh` as "SSH was never set up here".
	func overlaySSH(_ info: inout VMInfo, from host: HostedVM) {
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

	public func createVM(template: VMTemplate?) async throws -> VMInfo {
		try await local.createVM(template: template)
	}

	public func deleteVM(named name: String) async throws {
		try requireStopped(name, "deleting it")
		// Capture the marker BEFORE the identity file dies with the VM dir.
		let sshMarker = existingSSHMarker(name)
		try await local.deleteVM(named: name)
		launchAgents?.remove(vm: name, canBootout: true)
		if let sshMarker {
			revokeReverseKey(marker: sshMarker, vmName: name)
		}
		scheduleSSHHostConfigWrite()
	}

	// A deleted VM's guest→Mac grant leaves ~/.ssh/authorized_keys. Best-effort by nature —
	// the VM is gone, and the key's private half with it — but never silent (D11): a line
	// that stays is logged and shown, with what to remove by hand.
	func revokeReverseKey(marker: String, vmName name: String) {
		guard let writer = sshHostConfig else { return }
		do {
			try writer.setReverseKey(nil, marker: marker, vmName: name)
		} catch {
			MachmanLogger.log(.passiveWarning, "revoking \(name)'s reverse key: \(error)")
			registry.events.emit(.log(
				vm: name, level: .warning,
				message: "Couldn’t remove the guest’s key from ~/.ssh/authorized_keys — "
					+ "delete the line ending in machman:\(marker):\(name)"))
		}
	}

	public func renameVM(named name: String, to newName: String) async throws {
		try requireStopped(name, "renaming it")
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
		try await settingsOwner(name).setHardware(
			vm: name, cpuCount: cpuCount, memoryBytes: memoryBytes,
			nestedVirtualization: nestedVirtualization)
	}

	public func copyVM(
		vm name: String, newName: String?, diskIDs: [String]?, mountIDs: [String]?,
		regenerateMAC: Bool
	) async throws -> VMInfo {
		// Cloning images under an active writer produces torn copies.
		try requireStopped(name, "copying it")
		return try await local.copyVM(
			vm: name, newName: newName, diskIDs: diskIDs, mountIDs: mountIDs,
			regenerateMAC: regenerateMAC)
	}

	// Refused while hosted, not proxied: the running guest keeps the old MAC, and conflict
	// tracking captures macInUse at spawn — a mid-run change would desynchronize both.
	public func regenerateMAC(vm name: String) async throws -> VMInfo {
		try requireStopped(name, "regenerating its MAC")
		return try await local.regenerateMAC(vm: name)
	}

	public func addDisk(vm name: String, _ disk: NewDisk) async throws {
		try await settingsOwner(name).addDisk(vm: name, disk)
	}

	public func removeDisk(vm name: String, diskID: String) async throws {
		// Unlinking the backing file under a live VZ attachment is unsafe — stop first
		// (the guest would keep a ghost disk until shutdown, then the data is gone).
		try requireStopped(name, "removing its disks")
		try await local.removeDisk(vm: name, diskID: diskID)
	}

	// Import proxies deliberately: it is addDisk with a copy in front — the source is an
	// external file no attachment references, the owned image is NEW, and the config
	// addition is the hosted vmhost's to make (next-boot effect, like addDisk/addMount).
	public func importDisk(vm name: String, path: String) async throws -> VMInfo {
		try await settingsOwner(name).importDisk(vm: name, path: path)
	}

	// Refused while hosted, not proxied or deferred: the copy reads an image the live VZ
	// attachment holds open read-write (torn owned copy — copyVM's refusal reason), and the
	// config rewire under that attachment makes the next boot silently switch disks.
	public func promoteDisk(vm name: String, diskID: String) async throws -> VMInfo {
		try requireStopped(name, "promoting its disks")
		return try await local.promoteDisk(vm: name, diskID: diskID)
	}

	public func addMount(vm name: String, path: String, tag: String, kind: String?) async throws {
		try await settingsOwner(name).addMount(vm: name, path: path, tag: tag, kind: kind)
	}

	public func removeMount(vm name: String, mountID: String) async throws {
		try await settingsOwner(name).removeMount(vm: name, mountID: mountID)
	}

	// Serial ports are fixed at VM start, so add/remove is refused while hosted (like MAC), but
	// setSerialLogging proxies to the live bridge.
	public func addConsolePort(vm name: String) async throws {
		try requireStopped(name, "changing its serial ports")
		try await local.addConsolePort(vm: name)
	}

	public func removeConsolePort(vm name: String) async throws {
		try requireStopped(name, "changing its serial ports")
		try await local.removeConsolePort(vm: name)
	}

	public func addUartPort(vm name: String) async throws {
		try requireStopped(name, "changing its serial ports")
		try await local.addUartPort(vm: name)
	}

	public func removeUartPort(vm name: String) async throws {
		try requireStopped(name, "changing its serial ports")
		try await local.removeUartPort(vm: name)
	}

	public func setSerialLogging(
		vm name: String, kind: SerialPortKind, index: Int, config: SerialLogConfig
	) async throws {
		try await settingsOwner(name).setSerialLogging(
			vm: name, kind: kind, index: index, config: config)
	}

	public func setKernelBoot(vm name: String, enabled: Bool) async throws {
		try await settingsOwner(name).setKernelBoot(vm: name, enabled: enabled)
	}

	public func updateKernelSettings(vm name: String, _ settings: KernelSettings) async throws {
		try await settingsOwner(name).updateKernelSettings(vm: name, settings)
	}

	public func promoteKernelFile(
		vm name: String, role: KernelRole, sourcePath: String, tag: String
	) async throws -> VMInfo {
		try await settingsOwner(name).promoteKernelFile(
			vm: name, role: role, sourcePath: sourcePath, tag: tag)
	}

	public func deleteKernelFile(vm name: String, path: String) async throws -> VMInfo {
		try await settingsOwner(name).deleteKernelFile(vm: name, path: path)
	}

	public func setStartPolicy(vm name: String, policy: StartPolicy) async throws {
		// Resolved first: reaching the owner can adopt a host, and with it a safe run.
		let target = try await settingsOwner(name)
		// Policy has a daemon-side launchd side effect that must never reconcile against a
		// discardable shadow write — refuse rather than half-apply.
		if let host = hosted[name], host.identity.isSafe {
			throw MachmanError(
				code: .invalidState,
				message: "Run defaults can’t change during a safe run — stop \(name) "
					+ "or save it first")
		}
		try await target.setStartPolicy(vm: name, policy: policy)
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
		try await settingsOwner(name).setSafety(vm: name, disks: disks, mounts: mounts)
	}

	// MARK: - Guest devices (1.0.4) — config-plane edits proxy like disks (next-boot effect).

	public func addDevice(vm name: String, kind: DeviceKind) async throws -> VMInfo {
		try await settingsOwner(name).addDevice(vm: name, kind: kind)
	}

	public func removeDevice(vm name: String, kind: DeviceKind) async throws -> VMInfo {
		try await settingsOwner(name).removeDevice(vm: name, kind: kind)
	}

	public func updateDevice(vm name: String, device: DeviceInfo) async throws -> VMInfo {
		try await settingsOwner(name).updateDevice(vm: name, device: device)
	}

	public func setEnabled(
		vm name: String, disks: [String: Bool]?, mounts: [String: Bool]?,
		console: [String: Bool]?, uart: [String: Bool]?, devices: [String: Bool]?
	) async throws {
		try await settingsOwner(name).setEnabled(
			vm: name, disks: disks, mounts: mounts, console: console, uart: uart,
			devices: devices)
	}

	public func setKernelOverride(
		vm name: String, path: String, commandLine: String?, overrideEnabled: Bool?
	) async throws -> VMInfo {
		try await settingsOwner(name).setKernelOverride(
			vm: name, path: path, commandLine: commandLine, overrideEnabled: overrideEnabled)
	}

	public func resizeDisk(vm name: String, diskID: String, sizeBytes: UInt64) async throws
		-> VMInfo {
		// Growing the raw file under a live VZ attachment is unsafe — stop first.
		try requireStopped(name, "resizing its disks")
		return try await local.resizeDisk(vm: name, diskID: diskID, sizeBytes: sizeBytes)
	}
	public func renameDisk(vm name: String, diskID: String, newName: String) async throws
		-> VMInfo {
		// Moving the raw file under a live VZ attachment is unsafe — stop first.
		try requireStopped(name, "renaming its disks")
		return try await local.renameDisk(vm: name, diskID: diskID, newName: newName)
	}
	public func setMountTag(vm name: String, mountID: String, tag: String) async throws
		-> VMInfo {
		// Next-boot effect: safe to record on a hosted VM, like other mount edits.
		try await settingsOwner(name).setMountTag(vm: name, mountID: mountID, tag: tag)
	}
	public func setMountKind(vm name: String, mountID: String, kind: String) async throws
		-> VMInfo {
		// Next-boot effect: safe to record on a hosted VM, like other mount edits.
		try await settingsOwner(name).setMountKind(vm: name, mountID: mountID, kind: kind)
	}
	public func renameKernelFile(vm name: String, path: String, tag: String) async throws
		-> VMInfo {
		// The hosted VM's config references the old path — stop first.
		try requireStopped(name, "renaming its kernel files")
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
				message: "SSH settings can’t change during a safe run — stop \(name) "
					+ "or save it first")
		}
	}

	public func setSSH(
		vm name: String, integrationEnabled: Bool?, reverseApproved: Bool?, alias: String?
	) async throws -> VMInfo {
		// Resolved first: reaching the owner can adopt a host, and with it a safe run.
		let target = try await settingsOwner(name)
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
						message: "\(other.name) already answers to \u{201C}\(wanted)\u{201D}")
				}
			}
		}
		let info = try await target.setSSH(
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
		let target = try await settingsOwner(name)
		try refuseSSHWhileSafe(name)
		let marker = existingSSHMarker(name)
		let info = try await target.resetSSH(vm: name)
		if let writer = sshHostConfig, let marker {
			try? writer.setReverseKey(nil, marker: marker, vmName: name)
		}
		scheduleSSHHostConfigWrite()
		return info
	}

	// MARK: - Guest setup (1.0.7)

	public func resetSetup(vm name: String) async throws -> VMInfo {
		// Config-plane only (no daemon-side effects) — plain proxy, like device edits.
		try await settingsOwner(name).resetSetup(vm: name)
	}

	public func setSetupServed(vm name: String, serve: Bool) async throws -> VMInfo {
		// Routed to the vmhost while running: it owns the config there AND does the
		// live fill when serving turns on.
		try await settingsOwner(name).setSetupServed(vm: name, serve: serve)
	}

	// The marker labeling this VM's host-side artifacts — a read-only derivation from
	// the identity file, safe against the stale-while-hosted registry copy (paths only).
	func existingSSHMarker(_ name: String) -> String? {
		guard let config = registry.vm(named: name)?.config else { return nil }
		return SSHSetupInstaller.existingMarker(for: config)
	}

	// Rebuild ~/.ssh/machman/config (+ Include line) from current state. Fire-and-forget
	// with whole-state writes — concurrent triggers converge on last-write-wins.
	func scheduleSSHHostConfigWrite() {
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
	// in its vmhost, which runs its own OperationCenter). Hosts are asked at once and each
	// bounded like a list probe; a stalled host's operations are left out (E20).
	public func operations() async throws -> [OperationInfo] {
		var all = try await local.operations()
		let deadline = hostProbeDeadline
		let asks = hosted.values.map { host in
			Task { try? await host.client.operations(deadline: deadline) }
		}
		for ask in asks {
			if let ops = await ask.value {
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
		throw MachmanError(code: .notFound, message: "That operation already ended")
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
				code: .invalidState, message: "Rosetta isn’t supported on this Mac")
		case .notInstalled:
			break
		@unknown default:
			throw MachmanError(
				code: .invalidState,
				message: "Machman can’t tell whether this Mac supports Rosetta")
		}
		let center = local.operationCenter
		let opID = center.begin(
			kind: OperationInfo.Kind.rosettaInstall, label: "Installing Rosetta")
		VZLinuxRosettaDirectoryShare.installRosetta { error in
			Task { @MainActor in
				if let error {
					center.finish(
						opID, state: OperationInfo.State.failed,
						message: MachmanError.userMessage(for: error))
				} else {
					center.finish(opID, state: OperationInfo.State.succeeded)
				}
			}
		}
	}

	public func start(vm name: String, options: StartOptions) async throws {
		guard !pendingStarts.contains(name) else {
			throw MachmanError(code: .invalidState, message: "\(name) is already starting")
		}
		if let host = hosted[name] {
			// A host this daemon holds is not necessarily running its VM: ask it first.
			try await settleExistingHost(host, name: name)
			guard !pendingStarts.contains(name) else {   // the settle awaited
				throw MachmanError(code: .invalidState, message: "\(name) is already starting")
			}
		}
		guard let vm = registry.vm(named: name) else {
			throw MachmanError.notFound(name)
		}
		guard !registry.isInstalling(vm) else {
			throw MachmanError(
				code: .invalidState,
				message: "\(name) can’t start while macOS is installing")
		}
		// Reserved before the first await; the defer releases on every exit, success or
		// throw. Everything below (probe, spawn, shadow build) runs under this claim.
		reserveStart(name, mac: vm.config.macAddress)
		defer { releaseStart(name) }
		if let host = hosted[name] {
			// An idle host from an earlier start whose forward never happened (the daemon
			// died in between, E12): it takes this start instead of idling out — unless it
			// runs older code, and was ended for a fresh spawn below.
			if try await startOnExistingHost(
				host, name: name, mac: host.identity.macInUse ?? vm.config.macAddress,
				options: options) {
				return
			}
		}
		purgeDeadShadows(for: name)
		// A live vmhost may already own this VM's socket — launchd autostart, or a spawn
		// whose daemon died before forwarding start. Adopt it instead of racing it with a
		// second host. Deliberately ahead of the MAC-conflict guard: an already-running VM
		// is a fact, not a request — refusing to adopt it would strand it.
		let socketPath = hostSocketPath(for: name)
		if FileManager.default.fileExists(atPath: socketPath),
			try await probeAdoptAndStart(name: name, socketPath: socketPath, options: options) {
			return
		}
		try checkMACConflict(name: name, mac: vm.config.macAddress, options: options)
		try checkSharedDisks(name: name)
		if options.safe {
			try await startSafe(vm: vm, name: name, options: options)
			return
		}
		let identity = HostIdentity(
			id: UUID(), name: name, socketPath: hostSocketPath(for: name),
			macInUse: vm.config.macAddress)
		// The config the vmhost loads: nothing edits it while the start is reserved.
		let unattached = vm.config.unattachedDiskFiles
		let host = try await spawnHost(identity: identity, dataDir: machmanVMDir)
		do {
			try await forwardStart(host, name: name, options: options)
			host.markStarted()
		} catch {
			host.eventTask?.cancel()
			host.deathWatch?.invalidate()
			host.deathWatch = nil
			host.app?.forceTerminate()
			await host.client.disconnect()
			unlink(host.identity.socketPath)
			throw error
		}
		hostStarted(host, name: name, unattached: unattached)
	}

	// A spawned host whose start returned joins the hosted map, and the router announces the
	// run: the host's own running state came while it was not hosted, so it was not passed on
	// (O-6a). Clients that follow states (the desktop's previews) need the stateChanged; the
	// listChanged after it finds the VM running already, so a start still toasts once.
	// Internal for tests.
	func hostStarted(_ host: HostedVM, name: String, unattached: Set<String>) {
		host.unattachedDisks = unattached
		hosted[name] = host
		// Explicit kick, not the event filter: the vmhost emitted .running while start()
		// was still in flight — before the host was in `hosted`, where the filter looks it
		// up — so a fresh start would otherwise never discover (the filter still covers guest
		// reboots). A safe run's shadow impersonates the VM's MAC, so this covers it too.
		startSSHDiscovery(host)
		registry.events.emit(.stateChanged(vm: name, state: .running))
		registry.events.emit(.listChanged)
	}

	// The router is the only place that sees every live MAC: running hosts, and starts still
	// in their spawn window (nothing hosted yet). Among starts the earlier reservation wins,
	// so two same-MAC starts never both fail. Applies to safe runs too — the shadow
	// impersonates this VM's MAC. Internal for tests.
	func checkMACConflict(name: String, mac: String?, options: StartOptions) throws {
		guard !options.force, let mac else { return }
		if let clash = hosted.values.first(where: {
			$0.identity.name != name && $0.identity.macInUse == mac
		}) {
			throw MachmanError(
				code: .macConflict,
				message: "\(name) and the running VM \u{201C}\(clash.identity.name)\u{201D} "
					+ "share MAC address \(mac), so one of them would lose networking")
		}
		let mine = pendingStartMACs[name]?.order ?? Int.max
		let earlier = pendingStartMACs
			.filter { $0.key != name && $0.value.mac == mac && $0.value.order < mine }
			.min { $0.value.order < $1.value.order }
		if let other = earlier?.key {
			throw MachmanError(
				code: .macConflict,
				message: "\(name) and \u{201C}\(other)\u{201D}, which is starting, share MAC "
					+ "address \(mac), so one of them would lose networking")
		}
	}

	// No second writer of one disk file (C5): a VM saved from a safe run owns disks its
	// original references, and any VM may attach another's image. Running and starting VMs
	// count; isos (read-only) do not. `force` does NOT override it — lost networking
	// recovers, a disk written by two VMs does not. The starting VM attaches its enabled
	// entries, and so does a start still in flight (nothing edits its config meanwhile). A
	// running VM's flags can't decide: a disk switched off mid-run stays attached until it
	// stops, so every entry counts except the ones its start left disabled — known only for
	// a start this daemon made; for an adopted host each entry counts. Entries are never
	// removed or renamed while a VM runs, so the daemon's copy, however old, names all it
	// attached; a safe run's real config names files its shadow cloned, which only ever
	// over-refuses. Internal for tests.
	func checkSharedDisks(name: String) throws {
		guard let mine = registry.vm(named: name)?.config.writableDiskFiles, !mine.isEmpty
		else { return }
		for other in Set(hosted.keys).union(pendingStarts).subtracting([name]).sorted() {
			guard let config = registry.vm(named: other)?.config else { continue }
			let host = hosted[other]
			let theirs = host.map {
				config.everyWritableDiskFile.subtracting($0.unattachedDisks ?? [])
			} ?? config.writableDiskFiles
			guard let file = mine.intersection(theirs).sorted().first else { continue }
			let disk = (file as NSString).lastPathComponent
			// Only an adopted host's disabled entries name a file it may never have attached.
			let surely = host?.unattachedDisks != nil || config.writableDiskFiles.contains(file)
			throw MachmanError(
				code: .invalidState,
				message: (surely
					? "\(other) is running with \(disk) attached"
					: "\(other) may still have \(disk) attached")
					+ " — stop \(other) before starting \(name)")
		}
	}

	// A safe run: clone the VM into a shadow run root (per-disk/mount safe flags decide
	// clone-vs-reference / omit-vs-attach), run the vmhost against the shadow, and present
	// it AS the real VM. --library is passed ONLY here: it is the promotion destination and
	// its absence makes a vmhost refuse safeSave (the misattribution backstop).
	private func startSafe(vm: VirtualMachine, name: String, options: StartOptions) async throws {
		let runRoot = machmanSafeDir + "/" + SafeRun.runPrefix + UUID().uuidString
		let unattached = vm.config.unattachedDiskFiles   // the config the shadow copies
		do {
			try FileManager.default.createDirectory(
				atPath: runRoot, withIntermediateDirectories: true)
			// Phase-1 marker: intent, no pid yet — the sweep treats it as never-attachable.
			try SafeRun.writeMarker(
				ShadowMarker(vm: name, createdAt: Date(), pid: nil), runRoot: runRoot)
			let events = registry.events
			let center = local.operationCenter
			let opID = center.begin(
				kind: OperationInfo.Kind.shadowBuild, vm: name, label: Self.safeRunLabel)
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
					opID, state: OperationInfo.State.failed,
					message: MachmanError.userMessage(for: error))
				throw error
			}
			center.finish(opID, state: OperationInfo.State.succeeded)
		} catch {
			try? FileManager.default.removeItem(atPath: runRoot)
			throw error
		}
		var identity = HostIdentity(
			id: UUID(), name: name, socketPath: hostSocketPath(for: name),
			macInUse: vm.config.macAddress)
		identity.isSafe = true
		identity.shadowRoot = runRoot
		let library = machmanVMDir
		identity.library = library
		let host: HostedVM
		do {
			host = try await spawnHost(
				identity: identity, dataDir: runRoot, extraArguments: ["--library", library])
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
			try await forwardStart(host, name: name, options: forwarded)
			host.markStarted()
		} catch {
			host.eventTask?.cancel()
			host.deathWatch?.invalidate()
			host.deathWatch = nil
			host.app?.forceTerminate()
			await host.client.disconnect()
			unlink(host.identity.socketPath)
			try? FileManager.default.removeItem(atPath: runRoot)
			throw error
		}
		// The shadow keeps every entry's flag, so it left these unattached too.
		hostStarted(host, name: name, unattached: unattached)
	}

	// Internal seam (tests inject their own socket path): probe a socket that exists, adopt
	// whoever answers, and forward the start. Returns false when the socket was a dead
	// leftover — reclaimed, caller falls through to a fresh spawn.
	func probeAdoptAndStart(
		name: String, socketPath: String, options: StartOptions
	) async throws -> Bool {
		if let holder = hostHolding(socketPath), holder.identity.name != name {
			throw heldSocket(name, by: holder.identity.name)
		}
		let host: HostedVM
		do {
			host = try await connectAndAdopt(name: name, socketPath: socketPath)
		} catch {
			guard !UDSListener.isLive(path: socketPath) else {
				// NEVER unlink a live socket (single-writer rule) — whoever owns it may
				// recover; spawning over it would fork the VM's identity.
				throw MachmanError(
					code: .internalError,
					message: "\(name) is not responding")
			}
			unlink(socketPath)
			return false
		}
		guard host.identity.name == name else { throw heldSocket(name, by: host.identity.name) }
		// Other start failures propagate with the host still adopted: it is live and owns
		// the VM; its own lifecycle (or the user) cleans up. An outdated idle host was ended:
		// the caller spawns a current one.
		return try await startOnExistingHost(
			host, name: name, mac: host.identity.macInUse, options: options)
	}

	// E27: a run an older vmhost saved as a new VM still serves on its original's socket, so
	// no vmhost for the original can bind there until that run stops.
	private func heldSocket(_ name: String, by holder: String) -> MachmanError {
		MachmanError(
			code: .invalidState,
			message: "\(holder), saved from \(name), still runs on its socket — stop \(holder) "
				+ "before starting \(name)")
	}

	// A start meeting a host this daemon already holds (E12). A running VM is refused
	// (today's answer); a host that ran and stopped is exiting after its stop flush — a start
	// forwarded now would die with it — so it is waited out; an idle host that never ran is
	// let through for startOnExistingHost.
	private func settleExistingHost(_ host: HostedVM, name: String) async throws {
		switch await probe(host) {
		case .answered(let info) where info.state.isRunning:
			throw MachmanError(code: .invalidState, message: "\(name) is already running")
		case .answered:
			guard host.sawRun else { return }
		case .stalled:
			throw MachmanError(
				code: .invalidState, message: "\(name) is not responding")
		case .failed:
			break   // its connection is going: wait for it like an exit
		}
		guard await waitForHostGone(id: host.identity.id, timeout: hostExitGrace) else {
			throw MachmanError(
				code: .invalidState,
				message: "\(name) is still shutting down — try again in a moment")
		}
	}

	private func waitForHostGone(id: UUID, timeout: Duration) async -> Bool {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: timeout)
		while host(withID: id) != nil {
			guard clock.now < deadline else { return false }
			try? await Task.sleep(for: .milliseconds(50))
		}
		return true
	}

	// Hands a start to a host this daemon holds: an idle adopted one, or whoever answered
	// at probe-adopt. Its last answer decides. A running VM is a fact — adopt it as it is,
	// safe or not (a run cannot become safe retroactively). An idle host runs the real VM,
	// never a shadow, so a safe start is refused rather than quietly run unsafe, and the
	// MAC guard applies like any start. False when the host was idle but runs older code
	// than this daemon (E22): the run would start locked, so the host is ended instead and
	// the caller spawns a current one (R3-3). One the daemon cannot end still takes the
	// start, locked, rather than refusing every start until it idles out (RR3-3).
	private func startOnExistingHost(
		_ host: HostedVM, name: String, mac: String?, options: StartOptions
	) async throws -> Bool {
		if let answer = host.lastAnswer, answer.state == .stopped || answer.state == .error,
			!host.sawRun, isOutdated(host), try await endOutdatedIdleHost(host, name: name) {
			return false
		}
		if host.lastAnswer?.state.isRunning == true {
			if options.safe {
				MachmanLogger.log(.passiveWarning,
					"safe start requested for \(name), but a live vmhost already owns it")
			}
		} else {
			guard !options.safe else {
				throw MachmanError(
					code: .invalidState,
					message: "\(name) is still prepared from an earlier start — start it "
						+ "normally, or wait up to 3 minutes to start it safe")
			}
			try checkMACConflict(name: name, mac: mac, options: options)
			try checkSharedDisks(name: name)
		}
		var forwarded = options
		forwarded.safe = false
		do {
			// An adopted host holds its subscription from adopt(); this waits until it does.
			try await forwardStart(host, name: name, options: forwarded)
		} catch let error as MachmanError where error.code == .invalidState {
			// Already running (autostart got there first) — the caller still gets what they
			// asked for.
			host.markStarted()
			if options.openWindow {
				try? await host.client.openWindow(vm: name)
			}
			return true
		}
		host.markStarted()
		// The host emitted .running while start() was in flight — the subscription may have
		// seen it, but a kick is cheap and never misses (the plain start path's reasoning).
		startSSHDiscovery(host)
		registry.events.emit(.listChanged)
		return true
	}

	// True once the host is gone; false when there is nothing to end it by.
	private func endOutdatedIdleHost(_ host: HostedVM, name: String) async throws -> Bool {
		guard endIdleHost(host) else {
			MachmanLogger.log(.passiveWarning,
				"cannot end \(name)'s idle vmhost \(host.version), older than this daemon's "
					+ "\(daemonVersion) — the start runs on it, locked until \(name) restarts")
			return false
		}
		MachmanLogger.log(.log,
			"ending \(name)'s idle vmhost \(host.version), older than this daemon's "
				+ "\(daemonVersion), so the start runs on a current one")
		guard await waitForHostGone(id: host.identity.id, timeout: hostExitGrace) else {
			throw MachmanError(
				code: .invalidState,
				message: "\(name) is still shutting down — try again in a moment")
		}
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
		try await proxy(name).stop(vm: name, mode: mode)
	}

	public func openWindow(vm name: String) async throws {
		try await proxy(name).openWindow(vm: name)
	}

	public func closeWindow(vm name: String) async throws {
		try await proxy(name).closeWindow(vm: name)
	}

	// The preview poller's read, and it must never error: a VM that is starting (or whose
	// vmhost cannot be reached) simply has no preview yet.
	public func preview(vm name: String, maxWidth: Int?) async throws -> Data? {
		guard !pendingStarts.contains(name), let target = try? await proxy(name) else {
			return nil
		}
		guard let host = hosted[name] else {
			return try await target.preview(vm: name, maxWidth: maxWidth)
		}
		// Clients list only on listChanged, so a stall nobody lists would go unseen — but
		// this poll keeps coming. Bounded like a list probe; a miss checks the host the way
		// a list does (vm.get decides, so a merely slow frame never flips the mark), and a
		// marked host is not asked at all until its watcher hears from it.
		guard !host.unresponsive else { return nil }
		do {
			return try await host.client.preview(
				vm: name, maxWidth: maxWidth, deadline: hostProbeDeadline)
		} catch let error as MachmanError where error.code == .timeout {
			_ = await probe(host)
			return nil
		}
	}

	public func startMacInstall(vm name: String, source: InstallSource) async throws {
		try requireStopped(name, "installing macOS")
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
		guard registry.vm(named: newName) == nil, hosted[newName] == nil,
			!pendingStarts.contains(newName) else {
			throw MachmanError(
				code: .alreadyExists,
				message: "A VM named \u{201C}\(newName)\u{201D} already exists")
		}
		// The new name is claimed while the save is in flight: the vmhost serves at the new
		// name's socket before it replies, and nothing may start or late-adopt it there
		// meanwhile (residence says starting).
		reserveStart(newName, mac: nil)
		defer { releaseStart(newName) }
		let library = host.identity.library ?? machmanVMDir
		let hadSavedConfig = FileManager.default.fileExists(
			atPath: library + "/" + newName + "/config")
		// The vmhost moves the files (single writer); the daemon re-keys its view after.
		let info: VMInfo
		do {
			info = try await host.client.safeSave(vm: name, to: newName)
		} catch {
			listHalfSavedVM(
				newName, from: name, library: library, existedBefore: hadSavedConfig)
			throw error
		}
		return finishSafeSave(host, from: name, to: newName, reply: info)
	}

	// A save the vmhost could neither finish nor wholly undo (a moved disk, or the saved
	// folder, could not go back) leaves the saved VM in the library, and the vmhost rewrote
	// the configs to say where each disk is. List them as they are now, not after the next
	// daemon start. Internal so tests can run it under the redirect lock.
	func listHalfSavedVM(
		_ newName: String, from name: String, library: String, existedBefore: Bool
	) {
		guard !existedBefore,
			FileManager.default.fileExists(atPath: library + "/" + newName + "/config")
		else { return }
		do {
			_ = try registry.adoptFromDisk(name: newName, library: library)
		} catch {
			MachmanLogger.log(.passiveError,
				"Save as New VM left \(newName) in the library, but it can't be listed yet: "
					+ "\(error)")
		}
		registry.reload(name: name, library: library)
		registry.events.emit(.listChanged)
	}

	// The daemon's half once the vmhost replied, in ONE synchronous block. Internal so tests
	// can run it under the redirect lock: it reads both VMs' configs from disk.
	func finishSafeSave(
		_ host: HostedVM, from name: String, to newName: String, reply info: VMInfo
	) -> VMInfo {
		let library = host.identity.library ?? machmanVMDir
		guard hosted[name] === host else {
			// The run ended while it saved: the saved VM is on disk, stopped.
			_ = try? registry.adoptFromDisk(name: newName, library: library)
			registry.reload(name: name, library: library)
			registry.events.emit(.listChanged)
			var stopped = info
			stopped.state = .stopped
			return stopped
		}
		// The host keeps its live MAC. Keeping macInUse is deliberate: starting the ORIGINAL
		// now trips macConflict until the promoted VM reboots onto its fresh MAC. Its socket
		// moved to the saved VM's path before the reply — unless it is an older vmhost, which
		// keeps answering on the original's (adoption copes with both).
		let moved = hostSocketPath(for: newName)
		if moved != host.identity.socketPath, UDSListener.isLive(path: moved) {
			host.identity.socketPath = moved
		}
		host.identity.name = newName
		host.identity.isSafe = false
		host.identity.shadowRoot = nil   // the vmhost moved + deleted the run root itself
		// The host's reply is its answer for the promoted VM: a stall right after this serves
		// that, never an answer still naming the original.
		host.lastAnswer = info
		hosted[name] = nil
		hosted[newName] = host
		do {
			_ = try registry.adoptFromDisk(name: newName, library: library)
		} catch {
			// The host is live and keyed either way; the next listChanged/reload catches up.
			MachmanLogger.log(.passiveError,
				"promoted \(newName) is live but not yet adoptable: \(error)")
		}
		// The vmhost rewrote the ORIGINAL's config as well: the disks the run wrote directly
		// moved into the saved VM's folder, and the original references them there (C5).
		// The daemon's copy is from before the run.
		registry.reload(name: name, library: library)
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
			throw MachmanError(code: .invalidState, message: "This process can’t retire")
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

extension RoutingMachman: EventLineSource {
	func eventLines() -> AsyncStream<EventLine> {
		registry.events.lineStream()
	}
}
