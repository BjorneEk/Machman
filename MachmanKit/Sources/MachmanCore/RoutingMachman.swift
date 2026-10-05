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
//  This file holds the state, the residence seam and the MachmanControlling facade; the
//  responsibilities live beside it in RoutingMachman+HostSupervisor, +StartCoordinator,
//  +SSHPresence and +StartupReconciler.
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
	// while a copy writes into the VM's folder or reads it whole (D20).
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
		return try await withClaim(name, .copying, inDaemon: true) {
			try await local.copyVM(
				vm: name, newName: newName, diskIDs: diskIDs, mountIDs: mountIDs,
				regenerateMAC: regenerateMAC)
		}
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
		let target = try await settingsOwner(name)
		return try await withClaim(name, .importingDisk, inDaemon: target === local) {
			try await target.importDisk(vm: name, path: path)
		}
	}

	// Refused while hosted, not proxied or deferred: the copy reads an image the live VZ
	// attachment holds open read-write (torn owned copy — copyVM's refusal reason), and the
	// config rewire under that attachment makes the next boot silently switch disks.
	public func promoteDisk(vm name: String, diskID: String) async throws -> VMInfo {
		try requireStopped(name, "promoting its disks")
		return try await withClaim(name, .promotingDisk, inDaemon: true) {
			try await local.promoteDisk(vm: name, diskID: diskID)
		}
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
		let target = try await settingsOwner(name)
		return try await withClaim(name, .importingKernel, inDaemon: target === local) {
			try await target.promoteKernelFile(
				vm: name, role: role, sourcePath: sourcePath, tag: tag)
		}
	}

	public func deleteKernelFile(vm name: String, path: String) async throws -> VMInfo {
		try await settingsOwner(name).deleteKernelFile(vm: name, path: path)
	}

	public func setStartPolicy(vm name: String, policy: StartPolicy) async throws {
		// Resolved first: reaching the owner can adopt a host, and with it a safe run.
		let target = try await settingsOwner(name)
		// Policy has a daemon-side launchd side effect.
		try refuseWhileSafe(name, "Run defaults")
		// C8: never two VMs starting at login on one disk file or MAC. Read from the configs
		// on disk — a hosted VM's policy and disks are its vmhost's, saved there.
		if policy.autostart,
			let conflict = BootGuard.autostartConflict(turningOn: name, library: machmanVMDir) {
			throw conflict
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

	public func stop(vm name: String, mode: StopMode) async throws {
		// A VM still preparing a safe run has nothing running yet: stopping it cancels the
		// preparation, and its start fails as canceled (C14).
		if let cancel = claims.cancelHook(for: name) {
			cancel()
			return
		}
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
