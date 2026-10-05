//
//  RoutingMachman+StartCoordinator.swift
//  MachmanCore
//
//  vm.start and vm.safeSave: the start window's guards (MAC, shared disks, held
//  sockets), plain and safe starts, a start meeting a host the daemon already holds, and
//  the daemon's half of Save as New VM.
//

import Foundation
import AppKit
import MachmanAPI
import MachmanClient

extension RoutingMachman {
	// The shadow build's progress label; its card reads "<VM> — Preparing a safe run".
	nonisolated static let safeRunLabel = "Preparing a safe run"

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
		// Claimed before the first await; the defer releases on every exit, success or
		// throw. Everything below (probe, spawn, shadow build) runs under this claim.
		let claim = try claims.claim(name, .starting, mac: vm.config.macAddress)
		defer { claims.release(claim) }
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
			await abandonSpawnedHost(host)
			throw error
		}
		hostStarted(host, name: name, unattached: unattached)
	}

	// A spawned host whose start could not be handed over never joins the hosted map: end
	// it (the death watch first, so the kill can't re-enter hostGone) and free its socket.
	private func abandonSpawnedHost(_ host: HostedVM) async {
		host.eventTask?.cancel()
		host.deathWatch?.invalidate()
		host.deathWatch = nil
		host.app?.forceTerminate()
		await host.client.disconnect()
		unlink(host.identity.socketPath)
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
			await abandonSpawnedHost(host)
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

	public func safeSave(vm name: String, to newName: String) async throws -> VMInfo {
		guard let host = hosted[name], host.identity.isSafe else {
			throw MachmanError(
				code: .invalidState, message: "\(name) is not running in safe mode")
		}
		guard registry.vm(named: newName) == nil, hosted[newName] == nil,
			claims.claims(on: newName).isEmpty else {
			throw MachmanError(
				code: .alreadyExists,
				message: "A VM named \u{201C}\(newName)\u{201D} already exists")
		}
		// The new name is claimed while the save is in flight: the vmhost serves at the new
		// name's socket before it replies, and nothing may start or late-adopt it there
		// meanwhile (residence says starting).
		let claim = try claims.claim(newName, .saving)
		defer { claims.release(claim) }
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
}
