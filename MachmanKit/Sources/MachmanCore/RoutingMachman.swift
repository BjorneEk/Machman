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
//  This file holds the state, the residence seam and the MachmanControlling facade's lifecycle,
//  run and operation calls; the responsibilities live beside it: the per-VM setting changes in
//  RoutingMachman+ConfigRouting, the host table in HostedVM.swift and RoutingMachman+Adoption,
//  +Spawn, +Liveness and +Supervisor, then +StartCoordinator, +SSHPresence and
//  +StartupReconciler.
//

import Foundation
import AppKit
import Virtualization
import MachmanAPI
import MachmanClient

@MainActor
public final class RoutingMachman: MachmanControlling {
	let registry: VMRegistry
	let local: LocalMachman
	let daemonVersion: String
	// Injected (not built here) so unit tests can never touch ~/Library/LaunchAgents by
	// construction. nil = no agents are written; policy toggles still persist.
	let launchAgents: LaunchAgentManager?
	// Same rule for ~/.ssh: injected by the daemon, nil in tests — SSH switches still
	// persist, only the host-side files stay untouched. Every write goes through this one
	// owner (+SSHPresence).
	let sshFiles: SSHHostFiles?

	var hosted: [String: HostedVM] = [:]   // keyed by VM name

	// The start-window reservation, and every other claim on a VM's files (VMClaims).
	// `hosted[name]` is written only after the NSWorkspace launch, the connect poll, and (for
	// safe runs) a possibly minutes-long shadow build — so a guard that reads only `hosted`
	// has a window where a booting VM looks idle: a second start would adopt-then-kill the
	// half-spawned host, a delete would remove the directory under it, and a concurrent
	// purgeDeadShadows would eat the in-flight shadow build. A start claims its name from
	// start()'s first check until the start completed or failed. Internal as a test seam.
	let claims = VMClaims()

	// The names a start (or Save as New VM) holds, and the MAC each start will boot with and
	// the order the starts claimed in: the MAC-conflict check counts starts still in their
	// spawn window, and the earlier claim wins. Internal reads for tests.
	var pendingStarts: Set<String> { claims.startingNames }
	var pendingStartMACs: [String: (order: Int, mac: String)] { claims.startMACs }

	// Claims the name (and its MAC) for a start; internal so tests can stage a start in flight.
	func reserveStart(_ name: String, mac: String?) {
		claims.insert(name, .starting, mac: mac)
	}

	func releaseStart(_ name: String) {
		for claim in claims.claims(on: name) where claim.kind == .starting {
			claims.release(VMClaims.Token(name: name, order: claim.order))
		}
	}

	// E20: how long one vmhost may take to answer a list, get, operations or preview probe
	// before its VM is served from its last answer, marked unresponsive; and how often a
	// marked host is asked again. Internal seams for tests.
	var hostProbeDeadline: Duration = .seconds(3)
	var recoveryInterval: Duration = .seconds(2)
	var helloDeadline: Duration = .seconds(10)
	// How long a start waits for a host that is exiting after its VM stopped (E12).
	var hostExitGrace: Duration = .seconds(3)
	// How long a vmhost may take to answer a force stop (E36): the quit path's bound, and
	// inside a client's own 30 s for the call.
	var forceStopDeadline: Duration = .seconds(15)
	// Whether a vmhost process still exists (E8). A seam: an in-process test host's peer is
	// the test itself, so a test that ends a host says so here.
	var isProcessAlive: (Int32) -> Bool = SafeRun.defaultPidAlive
	// Ends a vmhost's process: an idle one that runs older code than this daemon, before a
	// start spawns a current one (R3-3) — it runs no VM, so a kill loses nothing — or one
	// that stopped answering, once the user confirmed it (vm.process.end, C9). False when it
	// could not: no app, and no peer pid that is still a vmhost's (RR3-3). Seams for the
	// same reason as isProcessAlive: an in-process test host's peer is the test.
	var endHost: (HostedVM) -> Bool = { host in
		if let app = host.app {
			return app.forceTerminate() || app.isTerminated
		}
		guard let pid = host.client.peerPID else { return false }
		return RoutingMachman.killVMHost(pid: pid)
	}
	// …and the process answering on a socket nobody adopted (the holder's pid).
	var endSocketHolder: (String) -> Bool = { path in
		guard let pid = UDSListener.holderPID(path: path) else { return false }
		return RoutingMachman.killVMHost(pid: pid)
	}

	// A safe start's shadow copy, and where its run roots go. Seams: a test runs a safe start
	// against a scratch dir with a copy that returns at once (review F9).
	var copyShadow: (VMCopyRequest) async throws -> Void = { request in
		_ = try await Task.detached(priority: .userInitiated) {
			try VMCopier.copy(request)
		}.value
	}
	var safeRunsDir: () -> String = { machmanSafeDir }

	// Late adoption (E21): one in-flight adoption per name, shared by every caller, and the
	// names whose live vmhost did not answer the last attempt (listed as not responding
	// until one gets through).
	var adoptions: [String: Task<HostedVM, Error>] = [:]
	var unadoptable: Set<String> = []
	var adoptionAttempts = 0   // test seam: connects made to adopt a host
	// An unadoptable name is asked again on its own timer, never by each list (E61). Short:
	// a vmhost that thaws reads running again within seconds, as it did when each list asked
	// it, and an attempt in flight then gets through at once. A seam for tests.
	var adoptionRetries: [String: Task<Void, Never>] = [:]
	var adoptionRetryInterval: Duration = .seconds(5)

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
		self.sshFiles = sshHostConfig.map(SSHHostFiles.init(writer:))
	}

	// MARK: - Host plumbing

	// Where a VM's vmhost serves. A test seam: the test runtime dir already sits at sun_path's
	// 104-byte limit, so routing tests point this into their scratch dir.
	var socketPathForVM: (String) -> String = { machmanVMSocketPath(vm: $0) }

	func hostSocketPath(for name: String) -> String {
		socketPathForVM(name)
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
			// A host on its way out would fail a call forwarded now ("The connection was
			// lost"): wait it out, then route to whatever owns the VM (E52). Not one that still
			// drains an import into its VM: it serves the VM until it exits.
			guard isWaitedOut(host) else { return host.client }
			try await waitOutLeaving(host, name: name)
			return try await proxy(name)
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
				throw notResponding(name)
			}
		case .local:
			return local
		}
	}

	// A VM whose vmhost doesn't answer, said one way with one code wherever it is met (E41):
	// clients key on the code.
	func notResponding(_ name: String) -> MachmanError {
		MachmanError(
			code: .invalidState, message: "\(name) is not responding — try again in a moment")
	}

	// Edits with daemon-side effects (launch agents, ~/.ssh) refuse during a safe run: those
	// effects must never reconcile against a discardable shadow write — refuse rather than
	// half-apply. `what` names the settings: "Run defaults", "SSH settings".
	func refuseWhileSafe(_ name: String, _ what: String) throws {
		if let host = hosted[name], host.identity.isSafe {
			throw MachmanError(
				code: .invalidState,
				message: "\(what) can’t change during a safe run — stop \(name) or save it first")
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
	// vmhost answering on its socket either, whether this daemon adopted it or not — and
	// while a copy writes into the VM's folder or reads it whole (D20). A vmhost on its way
	// out — its VM's run over, which clients already list as stopped, or its connection gone
	// — is waited out first (E52). Callers call it before they read any state: it may suspend.
	func requireStopped(_ name: String, _ action: String) async throws {
		switch residence(of: name) {
		case .hosted(let host):
			guard isLeaving(host) else {
				throw MachmanError(code: .invalidState, message: "Stop \(name) before \(action)")
			}
			// An import still draining into it answers at once, with no wait (isWaitedOut).
			if let busy = claims.refusal(for: name) { throw busy }
			try await waitOutLeaving(host, name: name)
			// The wait suspended: decide again on what owns the VM now — a start, a claim or
			// a host may have come meanwhile. The one waited for is gone, back, or draining.
			try await requireStopped(name, action)
		case .starting:
			throw MachmanError(
				code: .invalidState, message: "\(name) is starting — wait before \(action)")
		case .unadopted:
			throw MachmanError(
				code: .invalidState,
				message: "\(name) is still running — stop it before \(action)")
		case .local:
			if let busy = claims.refusal(for: name) { throw busy }
		}
	}

	// A long copy into (or out of) a VM's folder runs under a claim on the VM (PR14): a start
	// meanwhile would hand the config to a vmhost whose saves revert the copy's final edit
	// (E33), and a rename, delete or copy would move or read the folder under it (D20).
	// Claimed in the same main-actor turn the owner was resolved in, so nothing slips
	// between. `inDaemon`: the copy runs here, not in the VM's vmhost.
	func withClaim<Value>(
		_ name: String, _ kind: VMClaims.Kind, inDaemon: Bool,
		_ body: () async throws -> Value
	) async throws -> Value {
		let claim = try claims.claim(name, kind, inDaemon: inDaemon)
		defer { claims.release(claim) }
		return try await body()
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
			do {
				if let probed = probes[vm.name] {
					let result = await probed.answer.value
					// A host gone or re-keyed during the wait (a stop, safe-save) answered for
					// a run that is over: fall through to what owns the VM now.
					if hosted[vm.name] === probed.host {
						infos.append(try await presented(probed.host, result))
						continue
					}
				}
				infos.append(try await self.vm(named: vm.name))
			} catch let error as MachmanError where error.code == .notFound {
				// Deleted or renamed while the probes ran (E39): the list says what is there now.
				continue
			}
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

	public func createVM(template: VMTemplate?) async throws -> VMInfo {
		try await local.createVM(template: template)
	}

	public func deleteVM(named name: String) async throws {
		try await requireStopped(name, "deleting it")
		// Capture the marker BEFORE the identity file dies with the VM dir.
		let sshMarker = existingSSHMarker(name)
		try await local.deleteVM(named: name)
		launchAgents?.remove(vm: name, canBootout: true)
		if let sshMarker {
			revokeReverseKey(marker: sshMarker, vmName: name, announce: .always)
		}
		scheduleSSHHostConfigWrite()
	}

	public func renameVM(named name: String, to newName: String) async throws {
		try await requireStopped(name, "renaming it")
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

	public func copyVM(
		vm name: String, newName: String?, diskIDs: [String]?, mountIDs: [String]?,
		regenerateMAC: Bool
	) async throws -> VMInfo {
		// Cloning images under an active writer produces torn copies.
		try await requireStopped(name, "copying it")
		return try await withClaim(name, .copying, inDaemon: true) {
			try await local.copyVM(
				vm: name, newName: newName, diskIDs: diskIDs, mountIDs: mountIDs,
				regenerateMAC: regenerateMAC)
		}
	}

	public func refreshSSH(vm name: String) async throws {
		// Resolved like any per-VM call (E41): a running VM's vmhost the daemon hasn't adopted
		// yet is adopted, never taken for a stopped VM.
		_ = try await proxy(name)
		guard let host = hosted[name] else {
			throw MachmanError(
				code: .invalidState, message: "\(name) is not running — nothing to discover")
		}
		host.sshAnswer = nil
		startSSHDiscovery(host)
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

	// The daemon's own operations first, then every vmhost at once, each bounded like a list
	// probe (E40): a stalled host costs one deadline, never a queue in front of the host that
	// runs the operation. The owner's answer wins; then a host that didn't answer (it may be
	// the owner); then "already ended".
	public func cancelOperation(id: String) async throws {
		do {
			try await local.cancelOperation(id: id)
			return
		} catch let error as MachmanError where error.code == .notFound {
			// Not a daemon-side operation — try the vmhosts.
		}
		let deadline = hostProbeDeadline
		let asks = hosted.sorted { $0.key < $1.key }.map { name, host in
			(name, Task { () -> Error? in
				do {
					try await host.client.cancelOperation(id: id, deadline: deadline)
					return nil
				} catch {
					return error
				}
			})
		}
		var stalled: String?
		var refusal: Error?
		for (name, ask) in asks {
			guard let error = await ask.value else { return }
			switch (error as? MachmanError)?.code {
			case .notFound?: continue
			case .timeout?: stalled = stalled ?? name
			default: refusal = refusal ?? error
			}
		}
		if let refusal { throw refusal }
		if let stalled { throw notResponding(stalled) }
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

	// The C9 escalation, sent only after the user confirmed it a second time: end the
	// process of a VM's vmhost that doesn't answer — what a force stop couldn't reach.
	// Refused while the host answers; a plain stop never gets here.
	public func endProcess(vm name: String) async throws {
		switch residence(of: name) {
		case .hosted(let host):
			guard host.unresponsive else { throw answeringAgain(name) }
			try await endUnresponsiveHost(host, name: name)
		case .unadopted:
			if !unadoptable.contains(name), (try? await adoptLiveHost(name)) != nil {
				throw answeringAgain(name)
			}
			try await endUnadoptedHost(name)
		case .starting:
			throw MachmanError(
				code: .invalidState,
				message: "\(name) is starting — try again once it is running")
		case .local:
			throw MachmanError(code: .invalidState, message: "\(name) is not running")
		}
	}

	private func answeringAgain(_ name: String) -> MachmanError {
		MachmanError(
			code: .invalidState, message: "\(name) is answering again — use Force Stop")
	}

	public func stop(vm name: String, mode: StopMode) async throws {
		// A VM still preparing a safe run has nothing running yet: stopping it cancels the
		// preparation, and its start fails as canceled (C14).
		if let cancel = claims.cancelHook(for: name) {
			cancel()
			return
		}
		let target = try await proxy(name)
		guard let host = hosted[name] else {
			try await target.stop(vm: name, mode: mode)
			return
		}
		try await stopHosted(host, name: name, mode: mode)
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
		try await requireStopped(name, "installing macOS")
		try await local.startMacInstall(vm: name, source: source)
	}

	public func cancelMacInstall(vm name: String) async throws {
		try await local.cancelMacInstall(vm: name)
	}

	public func macInstallPhase(vm name: String) async throws -> InstallPhase {
		try await local.macInstallPhase(vm: name)
	}

	// Wired by the daemon app: stop serving and exit leave-VMs-running. The reply flushes
	// first — the handler only schedules the shutdown.
	public var onRetire: (() -> Void)?

	// The first piece of work this process runs itself, as the refusal that names it: a start
	// or copy whose work runs here (a proxied copy runs in its vmhost), or a macOS install,
	// whose half-downloaded restore image a successor would delete. nil when it runs none.
	// Sync, so tests can stage an install under the redirect lock.
	func daemonWorkRefusal() -> MachmanError? {
		if let (name, kind) = claims.inDaemon.first {
			return MachmanError(
				code: .invalidState,
				message: "\(name) \(kind.activity) — try again when it finishes")
		}
		if let installing = registry.list().filter(registry.isInstalling).map(\.name).min() {
			return MachmanError(
				code: .invalidState,
				message: "\(installing) is installing macOS — try again when it finishes")
		}
		return nil
	}

	public func retire() async throws {
		guard let onRetire else {
			throw MachmanError(code: .invalidState, message: "This process can’t retire")
		}
		// Vmhosts outlive this process; the work it runs itself dies with it (E45).
		if let busy = daemonWorkRefusal() { throw busy }
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
