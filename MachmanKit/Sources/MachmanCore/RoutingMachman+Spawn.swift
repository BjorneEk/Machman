//
//  RoutingMachman+Spawn.swift
//  MachmanCore
//
//  Spawning a VM's vmhost: its launch configuration and environment, the spawn's connect loop,
//  and the event subscription a start waits for before it is forwarded (E9).
//

import Foundation
import AppKit
import MachmanAPI
import MachmanClient

extension RoutingMachman {
	// A start that never connected. Its reason reads as a sentence, like the relayed errors
	// that can take its place ("Can’t connect: …", "It speaks API version 2 instead of 1").
	nonisolated static let hostNeverAnswered = "It never answered"

	nonisolated static let hostQuitWhileStarting = "It quit while starting"

	nonisolated static func hostDidNotStart(_ name: String, reason: String) -> String {
		"Machman VM for \(name) didn’t start: \(reason)"
	}

	// A spawn found the VM's socket served by another vmhost (E62) — a launch agent's for the
	// same VM, bound a moment before the one this start launched (which then quits, its path
	// taken). Not a failure: the start goes to the vmhost serving the VM.
	struct SpawnPathHeld: Error {}

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
		// The bundle id identifies the suite and the bundle version the vmhost's build (E22);
		// MACHMAN_VERSION is only the fallback for an unversioned build. The environment is
		// explicit (vmhostEnvironment): Launch Services merges it onto this agent's own.
		let lab = LabEnvironment.current
		let configuration = Self.vmhostLaunchConfiguration(
			arguments: [
				"--data-dir", dataDir, "--vm", name, "--socket", identity.socketPath,
			] + extraArguments,
			environment: Self.vmhostEnvironment(daemonVersion: daemonVersion, lab: lab))
		if let lab {
			MachmanLogger.log(.log, "test mode: vmhost for \(name) inherits "
				+ lab.forwardedVariables.keys.sorted().joined(separator: ", "))
		}

		let app: VMHostApp
		do {
			app = try await launchVMHost(vmhost.appURL, configuration)
		} catch {
			throw MachmanError(
				code: .internalError,
				message: "Couldn’t open Machman VM for \(name): "
					+ MachmanError.userMessage(for: error))
		}
		startsInFlight[name]?.app = app
		let hostID = identity.id
		let deathWatch = app.watchTermination { [weak self] in
			Task { @MainActor [weak self] in
				self?.hostGone(id: hostID)
			}
		}

		var lastError = Self.hostNeverAnswered
		var client: RemoteMachman?
		var held = false
		// The launch returns before the vmhost serves: it is asked every 250 ms, for 10 s. Only
		// the vmhost this spawn launched counts (E62): whoever else answers on the path, or
		// serves it once ours quit, holds the VM.
		_ = await poll(every: .milliseconds(250), for: spawnConnectWindow) {
			// Ended by a Force Stop or End Process (E64): the start fails as canceled.
			guard startsInFlight[name]?.canceled != true else { return true }
			guard !app.isTerminated else {
				held = UDSListener.isLive(path: identity.socketPath)
				lastError = Self.hostQuitWhileStarting
				return true
			}
			do {
				let answered = try await connectHost(identity: identity)
				guard answered.peerPID.map({ $0 == app.processIdentifier }) ?? true else {
					await answered.disconnect()
					held = true
					return true
				}
				client = answered
				return true
			} catch {
				lastError = MachmanError.userMessage(for: error)
				return false
			}
		}
		if let client, startsInFlight[name]?.canceled != true {
			return HostedVM(identity: identity, client: client, app: app, deathWatch: deathWatch)
		}
		await client?.disconnect()
		deathWatch.invalidate()
		if startsInFlight[name]?.canceled == true {
			app.forceTerminate()
			throw Self.startCanceled
		}
		if held {
			app.forceTerminate()
			MachmanLogger.log(.passiveWarning,
				"another vmhost serves \(name)'s socket — the start goes to it")
			throw SpawnPathHeld()
		}
		app.forceTerminate()
		throw MachmanError(
			code: .internalError, message: Self.hostDidNotStart(name, reason: lastError))
	}

	// How a vmhost is launched. Standalone, never a child: it is its own TCC responsible
	// process by construction — the same identity story as a launchd-started host. One
	// instance per VM under the shared bundle id, in the background, and quiet (E50): never
	// listed in Recent Items, and never a Launch Services prompt raised from a background
	// agent — a launch that would need one fails into spawnHost's error, which reaches the
	// client.
	nonisolated static func vmhostLaunchConfiguration(
		arguments: [String], environment: [String: String]
	) -> NSWorkspace.OpenConfiguration {
		let configuration = NSWorkspace.OpenConfiguration()
		configuration.createsNewApplicationInstance = true
		configuration.activates = false
		configuration.addsToRecentItems = false
		configuration.promptsUserIfNeeded = false
		configuration.arguments = arguments
		configuration.environment = environment
		return configuration
	}

	// The keys a vmhost keeps of what its agent inherited: the ones launchd gives every
	// process of the user's session (what a launchd-started vmhost sees, autostart), the home
	// and the locale.
	nonisolated static let vmhostKeptKeys: Set<String> = [
		"HOME", "CFFIXED_USER_HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "SHELL", "LANG",
		"SSH_AUTH_SOCK", "COMMAND_MODE", "XPC_FLAGS", "XPC_SERVICE_NAME",
		"__CF_USER_TEXT_ENCODING", "__CFBundleIdentifier",
	]

	// A vmhost's whole environment (E51). OpenConfiguration.environment MERGES onto the
	// launcher's own environment — it does not replace it — so whatever started the agent
	// would reach every vmhost: Xcode's DYLD_* and sanitizer variables, a script's
	// MACHMAN_DATA_DIR or MACHMAN_SUITE_ID. A merge can't unset a key, so every inherited key
	// outside the kept ones is overridden with an empty value; one that acts by being present
	// at all (DYLD_PRINT_*, MallocStackLogging) stays present, empty. Under a test suite the
	// vmhost also gets the suite, the fake home, the data dir and the lab's variables: without
	// them it would resolve the .dev suite (its sockets, its log subsystem) and run with test
	// mode off. A lab key never replaces MACHMAN_VERSION.
	nonisolated static func vmhostEnvironment(
		daemonVersion: String, lab: LabEnvironment?,
		inherited: [String: String] = ProcessInfo.processInfo.environment
	) -> [String: String] {
		var environment: [String: String] = [:]
		for key in inherited.keys where !vmhostKeptKeys.contains(key) {
			environment[key] = ""
		}
		environment.merge(lab?.forwardedVariables ?? [:]) { _, forwarded in forwarded }
		environment["MACHMAN_VERSION"] = daemonVersion
		return environment
	}

	// The subscription is made before anything else reaches the host, and `eventsSubscribed`
	// says when the host has it (E9). Each event goes on by the line the host sent it in, so a
	// newer vmhost's event types and fields reach clients whole (A10); the side effects here
	// read the decoded event.
	func subscribeEvents(_ host: HostedVM) {
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
					if let host = self.host(withID: id) { self.sshReportArrived(host) }
					// Report ingestion may have changed users/keys the managed file pins.
					self.scheduleSSHHostConfigWrite()
				}
				// Written to the log in its vmhost: passed on, not written again (E69).
				self.registry.events.emit(event, line: forwarded.line, logs: false)
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
	// The start stays reachable meanwhile (E64): a Force Stop or End Process ends this host,
	// and a spawned one — no list probes it, it isn't hosted — is watched like a list probe.
	func forwardStart(_ host: HostedVM, name: String, options: StartOptions) async throws {
		if let flight = startsInFlight[name] {
			flight.host = host
			if hosted[name] !== host { watchStartingHost(host, name: name, flight: flight) }
		}
		if host.eventsSubscribed == nil { subscribeEvents(host) }
		await host.eventsSubscribed?.value
		try await host.client.start(vm: name, options: options)
	}
}
