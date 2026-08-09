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
		let identity: HostIdentity
		let client: RemoteMachman
		// The spawned standalone app; nil for adopted hosts (their only death detector is the
		// socket disconnect, same as before). deathWatch routes isTerminated to hostGone —
		// invalidate it BEFORE forceTerminate on failure paths so a cleanup kill can't
		// re-enter (hostGone is idempotent anyway; this keeps the sequence obviously correct).
		let app: NSRunningApplication?
		var deathWatch: NSKeyValueObservation?
		var eventTask: Task<Void, Never>?

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

	public init(
		registry: VMRegistry, daemonVersion: String,
		launchAgents: LaunchAgentManager? = nil
	) {
		self.registry = registry
		self.local = LocalMachman(registry: registry)
		self.daemonVersion = daemonVersion
		self.launchAgents = launchAgents
	}

	var hostedNames: [String] { Array(hosted.keys) }

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
	// looks at VMs that still exist. Sweep the whole runtime dir instead.
	private func pruneDeadHostSockets() {
		let dir = machmanRuntimeDir
		guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
			return
		}
		for entry in entries where entry.hasPrefix("vm-") && entry.hasSuffix(".sock") {
			let path = dir + "/" + entry
			guard !UDSListener.isLive(path: path) else { continue }
			unlink(path)
			MachmanLogger.log(.log, "removed stale vmhost socket \(entry)")
		}
	}

	private func spawnHost(for name: String) async throws -> HostedVM {
		// Minted before any closure is built: termination and disconnect handlers capture the
		// identity's id, never the (re-keyable) name.
		let identity = HostIdentity(
			id: UUID(), name: name, socketPath: Self.hostSocketPath(for: name),
			macInUse: registry.vm(named: name)?.config.macAddress)
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
			"--data-dir", machmanVMDir, "--vm", name, "--socket", identity.socketPath,
		]
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
		registry.events.emit(.listChanged)
	}

	private func subscribeEvents(_ host: HostedVM) {
		host.eventTask = Task { [weak self] in
			let stream = await host.client.events()
			for await event in stream {
				guard let self = self else { return }
				self.registry.events.emit(event)
			}
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
		let client = host.client
		Task {
			await client.disconnect()
		}
		registry.reload(name: name)
		unlink(host.identity.socketPath)
		registry.events.emit(.stateChanged(vm: name, state: .stopped))
		registry.events.emit(.listChanged)
	}

	// Config/console-plane routing: a hosted VM's own process, else the daemon-local engine.
	private func target(_ name: String) -> MachmanControlling {
		if let host = hosted[name] { return host.client }
		return local
	}

	// MARK: - MachmanControlling

	public func hostCapabilities() async throws -> HostCapabilities {
		try await local.hostCapabilities()
	}

	public func listVMs() async throws -> [VMInfo] {
		var infos: [VMInfo] = []
		for vm in registry.list() {
			if let host = hosted[vm.name],
				let info = try? await host.client.vm(named: vm.name) {
				infos.append(info)
				continue
			}
			infos.append(try await local.vm(named: vm.name))
		}
		return infos
	}

	public func vm(named name: String) async throws -> VMInfo {
		if let host = hosted[name], let info = try? await host.client.vm(named: name) {
			return info
		}
		return try await local.vm(named: name)
	}

	public func createVM() async throws -> VMInfo {
		try await local.createVM()
	}

	public func deleteVM(named name: String) async throws {
		guard hosted[name] == nil else {
			throw MachmanError(code: .invalidState, message: "stop \(name) before deleting it")
		}
		try await local.deleteVM(named: name)
		launchAgents?.remove(vm: name, canBootout: true)
	}

	public func renameVM(named name: String, to newName: String) async throws {
		guard hosted[name] == nil else {
			throw MachmanError(code: .invalidState, message: "stop \(name) before renaming it")
		}
		try await local.renameVM(named: name, to: newName)
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

	public func setHardware(vm name: String, cpuCount: Int?, memoryBytes: UInt64?) async throws {
		try await target(name).setHardware(vm: name, cpuCount: cpuCount, memoryBytes: memoryBytes)
	}

	public func copyVM(
		vm name: String, newName: String?, diskIDs: [String]?, regenerateMAC: Bool
	) async throws -> VMInfo {
		// Cloning images under an active writer produces torn copies.
		guard hosted[name] == nil else {
			throw MachmanError(code: .invalidState, message: "stop \(name) before copying it")
		}
		return try await local.copyVM(
			vm: name, newName: newName, diskIDs: diskIDs, regenerateMAC: regenerateMAC)
	}

	// Refused while hosted, not proxied: the running guest keeps the old MAC, and conflict
	// tracking captures macInUse at spawn — a mid-run change would desynchronize both.
	public func regenerateMAC(vm name: String) async throws -> VMInfo {
		guard hosted[name] == nil else {
			throw MachmanError(
				code: .invalidState, message: "stop \(name) before regenerating its MAC")
		}
		return try await local.regenerateMAC(vm: name)
	}

	public func addDisk(vm name: String, _ disk: NewDisk) async throws {
		try await target(name).addDisk(vm: name, disk)
	}

	public func removeDisk(vm name: String, diskID: String) async throws {
		try await target(name).removeDisk(vm: name, diskID: diskID)
	}

	public func addMount(vm name: String, path: String, tag: String) async throws {
		try await target(name).addMount(vm: name, path: path, tag: tag)
	}

	public func removeMount(vm name: String, mountID: String) async throws {
		try await target(name).removeMount(vm: name, mountID: mountID)
	}

	public func setKernelBoot(vm name: String, enabled: Bool) async throws {
		try await target(name).setKernelBoot(vm: name, enabled: enabled)
	}

	public func updateKernelSettings(vm name: String, _ settings: KernelSettings) async throws {
		try await target(name).updateKernelSettings(vm: name, settings)
	}

	public func setStartPolicy(vm name: String, policy: StartPolicy) async throws {
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

	public func start(vm name: String, options: StartOptions) async throws {
		guard hosted[name] == nil else {
			throw MachmanError(code: .invalidState, message: "\(name) is already running")
		}
		// Honest refusal until the shadow-run commit lands — never silently run unsafely.
		guard !options.safe else {
			throw MachmanError(
				code: .invalidArgument, message: "safe runs are not available yet")
		}
		guard let vm = registry.vm(named: name) else {
			throw MachmanError.notFound(name)
		}
		guard !registry.isInstalling(vm) else {
			throw MachmanError(
				code: .invalidState,
				message: "(\(name)) cannot start while macOS is installing")
		}
		// A live vmhost may already own this VM's socket — launchd autostart, or a spawn
		// whose daemon died before forwarding start. Adopt it instead of racing it with a
		// second host. Deliberately ahead of the MAC-conflict guard: an already-running VM
		// is a fact, not a request — refusing to adopt it would strand it.
		let socketPath = Self.hostSocketPath(for: name)
		if FileManager.default.fileExists(atPath: socketPath),
			try await probeAdoptAndStart(name: name, socketPath: socketPath, options: options) {
			return
		}
		// The router is the only place that sees every host's live MAC.
		if !options.force, let mac = vm.config.macAddress,
			let clash = hosted.values.first(where: { $0.identity.macInUse == mac }) {
			throw MachmanError(
				code: .macConflict,
				message: "\(name) uses MAC \(mac), which running VM "
					+ "'\(clash.identity.name)' is already using — one of them would lose "
					+ "networking. Stop it, regenerate a MAC, or force start.")
		}
		let host = try await spawnHost(for: name)
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
		do {
			try await client.start(vm: name, options: options)
		} catch let error as MachmanError where error.code == .invalidState {
			// Already running (autostart got there first) — the caller still gets what
			// they asked for.
			if options.openConsole {
				try? await client.openConsole(vm: name)
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

	public func openConsole(vm name: String) async throws {
		try await target(name).openConsole(vm: name)
	}

	public func closeConsole(vm name: String) async throws {
		try await target(name).closeConsole(vm: name)
	}

	public func consoleInfo(vm name: String) async throws -> ConsoleInfo {
		try await target(name).consoleInfo(vm: name)
	}

	public func preview(vm name: String, maxWidth: Int?) async throws -> Data? {
		try await target(name).preview(vm: name, maxWidth: maxWidth)
	}

	public func startMacInstall(vm name: String, source: InstallSource) async throws {
		guard hosted[name] == nil else {
			throw MachmanError(
				code: .invalidState, message: "Stop the VM before installing macOS")
		}
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
