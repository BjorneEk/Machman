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
import MachmanAPI
import MachmanClient

@MainActor
public final class RoutingMachman: MachmanControlling {
	private let registry: VMRegistry
	private let local: LocalMachman
	private let daemonVersion: String

	// Everything the daemon knows about one vmhost, fixed at spawn/adopt time. Stored, never
	// recomputed: hostGone unlinks identity.socketPath and closures capture identity.id, so
	// both survive any future re-keying of `hosted` (safe mode re-keys on save-as-new).
	struct HostIdentity {
		let id: UUID
		var name: String
		let socketPath: String
		var isSafe = false           // inert until safe mode (phase 6)
		var shadowRoot: String?      // inert until safe mode (phase 6)
		var macInUse: String?        // inert until MAC-conflict detection (phase 3.5)
	}

	final class HostedVM {
		let identity: HostIdentity
		let client: RemoteMachman
		let process: Process?     // nil for adopted hosts (spawned by an earlier daemon)
		var eventTask: Task<Void, Never>?

		init(identity: HostIdentity, client: RemoteMachman, process: Process?) {
			self.identity = identity
			self.client = client
			self.process = process
		}
	}
	private var hosted: [String: HostedVM] = [:]   // keyed by VM name

	public init(registry: VMRegistry, daemonVersion: String) {
		self.registry = registry
		self.local = LocalMachman(registry: registry)
		self.daemonVersion = daemonVersion
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
			let identity = HostIdentity(id: UUID(), name: name, socketPath: socketPath)
			do {
				let client = try await connectHost(identity: identity)
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
			id: UUID(), name: name, socketPath: Self.hostSocketPath(for: name))
		let executable = Bundle.main.bundleURL
			.appendingPathComponent("Contents/MacOS/MachmanVMHost")
		guard FileManager.default.fileExists(atPath: executable.path) else {
			throw MachmanError(
				code: .internalError,
				message: "MachmanVMHost helper missing at \(executable.path)")
		}
		let process = Process()
		process.executableURL = executable
		process.arguments = [
			"--data-dir", machmanVMDir, "--vm", name, "--socket", identity.socketPath,
		]
		var environment = ProcessInfo.processInfo.environment
		// The vmhost is a bare tool with no Info.plist, so it cannot read the suite identifier
		// the way an app bundle does — hand it down explicitly or it would fall back to the
		// production identifier. --data-dir and --socket are still authoritative for paths.
		environment["MACHMAN_SUITE_ID"] = MachmanPaths.suiteIdentifier()
		environment["MACHMAN_VERSION"] = daemonVersion
		environment.removeValue(forKey: "MACHMAN_DATA_DIR")
		process.environment = environment
		let hostID = identity.id
		process.terminationHandler = { [weak self] _ in
			Task { @MainActor [weak self] in
				self?.hostGone(id: hostID)
			}
		}
		try process.run()

		var lastError = "vmhost never answered"
		for _ in 0..<40 {
			try? await Task.sleep(for: .milliseconds(250))
			guard process.isRunning else {
				lastError = "vmhost exited during startup"
				break
			}
			do {
				let client = try await connectHost(identity: identity)
				return HostedVM(identity: identity, client: client, process: process)
			} catch {
				lastError = "\(error)"
			}
		}
		process.terminationHandler = nil
		process.terminate()
		throw MachmanError(
			code: .internalError, message: "vmhost for \(name) failed to start: \(lastError)")
	}

	func connectHost(identity: HostIdentity) async throws -> RemoteMachman {
		let hostID = identity.id
		return try await RemoteMachman(
			socketPath: identity.socketPath, clientName: "machmand-router",
			onDisconnect: { [weak self] in
				Task { @MainActor [weak self] in
					self?.hostGone(id: hostID)
				}
			})
	}

	func adopt(identity: HostIdentity, client: RemoteMachman) {
		let host = HostedVM(identity: identity, client: client, process: nil)
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
	}

	public func renameVM(named name: String, to newName: String) async throws {
		guard hosted[name] == nil else {
			throw MachmanError(code: .invalidState, message: "stop \(name) before renaming it")
		}
		try await local.renameVM(named: name, to: newName)
	}

	public func setHardware(vm name: String, cpuCount: Int?, memoryBytes: UInt64?) async throws {
		try await target(name).setHardware(vm: name, cpuCount: cpuCount, memoryBytes: memoryBytes)
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

	public func start(vm name: String, options: StartOptions) async throws {
		guard hosted[name] == nil else {
			throw MachmanError(code: .invalidState, message: "\(name) is already running")
		}
		guard let vm = registry.vm(named: name) else {
			throw MachmanError.notFound(name)
		}
		guard !registry.isInstalling(vm) else {
			throw MachmanError(
				code: .invalidState,
				message: "(\(name)) cannot start while macOS is installing")
		}
		let host = try await spawnHost(for: name)
		do {
			try await host.client.start(vm: name, options: options)
		} catch {
			host.process?.terminationHandler = nil
			host.process?.terminate()
			await host.client.disconnect()
			unlink(host.identity.socketPath)
			throw error
		}
		hosted[name] = host
		subscribeEvents(host)
		registry.events.emit(.listChanged)
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

	public func events() async -> AsyncStream<VMEvent> {
		registry.events.stream()
	}
}
