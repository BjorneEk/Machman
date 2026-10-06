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
		// Another start, or a copy into the VM (E33): its final config edit would land under
		// the vmhost this start launches, whose own saves then revert it.
		if let busy = claims.refusal(for: name) { throw busy }
		if let host = hosted[name] {
			// A host this daemon holds is not necessarily running its VM: ask it first.
			try await settleExistingHost(host, name: name)
			if let busy = claims.refusal(for: name) { throw busy }   // the settle awaited
		}
		guard let vm = registry.vm(named: name) else {
			throw MachmanError.notFound(name)
		}
		// A boot mode a newer Machman wrote never boots here (C11): refused before any vmhost
		// is launched for it.
		try vm.config.requireStartableBoot()
		guard !registry.isInstalling(vm) else {
			throw MachmanError(
				code: .invalidState,
				message: "\(name) can’t start while macOS is installing")
		}
		// Claimed before the first await; the defer releases on every exit, success or
		// throw. Everything in launch (probe, spawn, shadow build) runs under this claim.
		let claim = try claims.claim(name, .starting, mac: vm.config.macAddress)
		defer { claims.release(claim) }
		do {
			try await launch(vm, name: name, options: options, claim: claim)
		} catch {
			// The VM listed as starting since the claim: a client that lists on listChanged
			// would keep showing it starting after the start failed.
			registry.events.emit(.listChanged)
			throw error
		}
	}

	// A start under its claim: hand it to a host that already serves the VM, or spawn one.
	private func launch(
		_ vm: VirtualMachine, name: String, options: StartOptions, claim: VMClaims.Token
	) async throws {
		await adoptOtherUnadoptedHosts(than: name)
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
			try await startSafe(vm: vm, name: name, options: options, claim: claim)
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
		guard !options.force else { return }
		try BootGuard.checkMAC(
			BootGuard.Candidate(name: name, mac: mac, order: pendingStartMACs[name]?.order),
			among: bootGuardOthers())
	}

	// No second writer of one disk file (C5): a VM saved from a safe run owns disks its
	// original references, and any VM may attach another's image. Running and starting VMs
	// count; isos (read-only) do not. `force` does NOT override it — lost networking
	// recovers, a disk written by two VMs does not. The starting VM attaches its enabled
	// entries. Internal for tests.
	func checkSharedDisks(name: String) throws {
		guard let mine = registry.vm(named: name)?.config.writableDiskFiles else { return }
		try BootGuard.checkDisks(
			BootGuard.Candidate(name: name, disks: mine), among: bootGuardOthers())
	}

	// A vmhost nobody adopted yet — a launch-agent start that bound after startup adoption, a
	// host that missed hello — runs a VM the boot guard has to see (E37). Each is adopted
	// first, at once; one that can't be still counts, from the daemon's copy of its config.
	// One whose last adoption already failed isn't asked again here: it would cost every
	// start its hello and answer deadlines, and the guard counts it anyway (review F8).
	private func adoptOtherUnadoptedHosts(than name: String) async {
		let unadopted = registry.list().map(\.name).filter {
			$0 != name && !unadoptable.contains($0) && isUnadopted($0)
		}
		guard !unadopted.isEmpty else { return }
		_ = await adoptLiveHosts(unadopted)
	}

	private func isUnadopted(_ name: String) -> Bool {
		if case .unadopted = residence(of: name) { return true }
		return false
	}

	// Every VM that runs or starts, as the boot guard sees it. A start still in flight
	// attaches its enabled entries (nothing edits its config meanwhile). A running VM's flags
	// can't decide: a disk switched off mid-run stays attached until it stops, so every entry
	// counts except the ones its start left disabled — known only for a start this daemon
	// made; for an adopted host each entry counts, the disabled ones as "may have". Entries
	// are never removed or renamed while a VM runs, so the daemon's copy, however old, names
	// all it attached; a safe run's real config names files its shadow cloned, which only
	// ever over-refuses. A vmhost that couldn't be adopted counts with the config's MAC and
	// every entry it may have attached.
	func bootGuardOthers() -> [BootGuard.Other] {
		var others: [BootGuard.Other] = []
		for (name, host) in hosted {
			var other = BootGuard.Other(name: name, role: .running, mac: host.identity.macInUse)
			if let config = registry.vm(named: name)?.config {
				if let unattached = host.unattachedDisks {
					other.attached = config.everyWritableDiskFile.subtracting(unattached)
				} else {
					other.attached = config.writableDiskFiles
					other.mayHaveAttached = config.unattachedDiskFiles
				}
			}
			others.append(other)
		}
		let macs = pendingStartMACs
		for name in pendingStarts {
			let order = macs[name]?.order ?? Int.max
			var other = BootGuard.Other(
				name: name, role: .starting(order: order), mac: macs[name]?.mac)
			// A hosted one's disks are its host's (above).
			if hosted[name] == nil {
				other.attached = registry.vm(named: name)?.config.writableDiskFiles ?? []
			}
			others.append(other)
		}
		for vm in registry.list() where hosted[vm.name] == nil && isUnadopted(vm.name) {
			others.append(BootGuard.Other(
				name: vm.name, role: .running, mac: vm.config.macAddress,
				mayHaveAttached: vm.config.everyWritableDiskFile))
		}
		return others
	}

	// A safe run: clone the VM into a shadow run root (per-disk/mount safe flags decide
	// clone-vs-reference / omit-vs-attach), run the vmhost against the shadow, and present
	// it AS the real VM. --library is passed ONLY here: it is the promotion destination and
	// its absence makes a vmhost refuse safeSave (the misattribution backstop).
	private func startSafe(
		vm: VirtualMachine, name: String, options: StartOptions, claim: VMClaims.Token
	) async throws {
		let runRoot = safeRunsDir() + "/" + SafeRun.runPrefix + UUID().uuidString
		let unattached = vm.config.unattachedDiskFiles   // the config the shadow copies
		do {
			try FileManager.default.createDirectory(
				atPath: runRoot, withIntermediateDirectories: true)
			// Phase-1 marker: intent, no pid yet — the sweep treats it as never-attachable.
			try SafeRun.writeMarker(
				ShadowMarker(vm: name, createdAt: Date(), pid: nil), runRoot: runRoot)
			let build = beginShadowBuild(vm, runRoot: runRoot)
			let center = local.operationCenter
			// Nothing runs yet: a stop meanwhile cancels the preparation (C14).
			claims.setCancel(claim) { build.canceled.set() }
			defer { claims.setCancel(claim, nil) }
			// Detached: same-volume clones are instant, but unsafe-marked-safe external
			// images can be real byte copies.
			do {
				try await copyShadow(build.request)
			} catch {
				let canceled = build.canceled.get()
				center.finish(
					build.operation,
					state: canceled ? OperationInfo.State.cancelled : OperationInfo.State.failed,
					message: MachmanError.userMessage(for: error))
				throw canceled ? Self.safeRunCanceled : error
			}
			// A cancel that landed after the copy's last look at it, or while its result
			// waited for the main actor, still cancels: nothing runs yet (review F9). No await
			// comes between here and the spawn, so no later stop slips past this check.
			guard !build.canceled.get() else {
				center.finish(
					build.operation, state: OperationInfo.State.cancelled,
					message: Self.safeRunCanceled.message)
				throw Self.safeRunCanceled
			}
			center.finish(build.operation, state: OperationInfo.State.succeeded)
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

	nonisolated static let safeRunCanceled = MachmanError(
		code: .cancelled, message: "The safe run was canceled")

	struct ShadowBuild {
		let operation: String
		let canceled: CancelFlag
		let request: VMCopyRequest
	}

	// A safe start's shadow copy: its operation card and the copy request, both reporting to
	// the card and both stopped by its cancel (E35). Copies nothing itself — a sync seam.
	func beginShadowBuild(_ vm: VirtualMachine, runRoot: String) -> ShadowBuild {
		let name = vm.config.name
		let events = registry.events
		let center = local.operationCenter
		let canceled = CancelFlag()
		let operation = center.begin(
			kind: OperationInfo.Kind.shadowBuild, vm: name, label: Self.safeRunLabel,
			cancel: { canceled.set() })
		var request = SafeRun.shadowRequest(
			config: vm.config, sourceDir: machmanVMDir + "/" + name, runRoot: runRoot,
			progress: { copied, total in
				Task { @MainActor in
					events.emit(.copyProgress(vm: name, copiedBytes: copied, totalBytes: total))
					center.update(
						operation, fraction: total > 0 ? Double(copied) / Double(total) : nil,
						completedBytes: Int64(copied), totalBytes: Int64(total))
				}
			})
		request.isCancelled = { canceled.get() }
		return ShadowBuild(operation: operation, canceled: canceled, request: request)
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
			// NEVER unlink a live socket (single-writer rule) — whoever owns it may recover;
			// spawning over it would fork the VM's identity. A dead one goes, in turn with a
			// vmhost starting on the path (review F13).
			guard BoundSocket.removeIfDead(socketPath) != .live else {
				throw notResponding(name)
			}
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
			throw notResponding(name)
		case .failed:
			break   // its connection is going: wait for it like an exit
		}
		guard await waitForHostGone(id: host.identity.id, timeout: hostExitGrace) else {
			throw MachmanError(
				code: .invalidState,
				message: "\(name) is still shutting down — try again in a moment")
		}
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
		guard endHost(host) else {
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
		// Resolved like any per-VM call (E41): adopting a vmhost the daemon hasn't met yet
		// re-attaches the safe run it may be serving.
		_ = try await proxy(name)
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
		// Either way the library gained a VM: ~/.ssh/machman follows it, as after a copy (C27).
		defer { scheduleSSHHostConfigWrite() }
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
