//
//  RoutingMachman+StartupReconciler.swift
//  MachmanCore
//
//  What the daemon runs once at startup, in MachmanAgentApp's order: prune dead sockets
//  and adopt surviving vmhosts, sweep safe-run roots and stopped VMs' leftovers, store
//  collision aliases, heal launch agents. Also the safe-run root scans a late adoption
//  and every start reuse.
//

import Foundation
import MachmanAPI
import MachmanClient

extension RoutingMachman {
	// Adopt vmhosts left behind by an earlier daemon: a live host answers on its socket and
	// keeps running (its VM never noticed the daemon restart); a stale socket is reclaimed.
	// This is the daemon's whole startup reconciliation, so it also has to cope with the
	// ungraceful cases — force quit, crash, power loss — where nothing got to clean up.
	// Every request but hello and retire waits for this, so the hosts are adopted at once
	// (E43): one at a time, two or three busy hosts outlasted a client's first vm.list.
	public func adoptExistingHosts() async {
		pruneDeadHostSockets()
		await identifyOrphanedHosts(in: machmanRuntimeDir)
		let names = registry.list().map(\.name).filter { name in
			let socketPath = hostSocketPath(for: name)
			return hosted[name] == nil && FileManager.default.fileExists(atPath: socketPath)
				&& hostHolding(socketPath) == nil
		}
		let adoptions = await adoptLiveHosts(names)
		for name in names {
			switch adoptions[name] {
			case .success(let host):
				MachmanLogger.log(.log, "adopted running vmhost for \(host.identity.name)")
			case .failure(let error):
				// NEVER unlink a live socket (single-writer rule, probe-adopt's guard): a
				// vmhost whose main actor is busy misses hello but still owns the VM.
				// Without its socket it turned invisible and unstoppable, and the next start
				// spawned a second VZ against the same disks (E21).
				let socketPath = hostSocketPath(for: name)
				guard BoundSocket.removeIfDead(socketPath) != .live else {
					MachmanLogger.log(.passiveWarning,
						"kept \(name)'s live vmhost socket (\(error)) — adopting it on next use")
					continue
				}
			case nil:
				break
			}
		}
	}

	// A running VM whose folder was renamed or moved away while no daemon watched still serves
	// on its old name's socket, which adoption — asking only the current names' sockets —
	// never asks (E11): invisible and unstoppable, its renamed entry listed stopped, and a
	// Start booted a second VZ on the same disks. Every live vmhost socket no VM accounts for
	// is asked whom it serves (hello), all at once: one serving an entry's folder makes that
	// entry Not responding until it exits (a Start is refused, End Process ends it); any other
	// is logged and left running. One that doesn't answer in time (a stalled main actor) is
	// asked again on the adoption timer until it answers or its socket goes dark (F23). A
	// vmhost from before hello said so can't be placed.
	func identifyOrphanedHosts(in dir: String) async {
		let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
		let known = Set(registry.list().map { socketPathForVM($0.name) })
			.union(hosted.values.map(\.identity.socketPath))
		let unclaimed = entries.filter { $0.hasPrefix("vm-") && $0.hasSuffix(".sock") }
			.map { dir + "/" + $0 }
			.filter { !known.contains($0) && UDSListener.isLive(path: $0) }
		let asks = unclaimed.map { path in (path, Task { await self.whomItServes(path) }) }
		for (path, ask) in asks {
			guard let served = await ask.value else {
				MachmanLogger.log(.passiveWarning,
					"a vmhost answers on \(path), for no VM in the library, and didn't say whom "
						+ "it serves — asking it again")
				askAgain(path)
				continue
			}
			noteOrphan(served, at: path)
		}
	}

	// One timer per socket, until it says whom it serves, goes dark, or a VM claims it.
	private func askAgain(_ path: String) {
		guard orphanQuestions[path] == nil else { return }
		orphanQuestions[path] = Task { [weak self] in
			while let interval = self?.adoptionRetryInterval {
				try? await Task.sleep(for: interval)
				guard let self, !Task.isCancelled, UDSListener.isLive(path: path),
					!self.isClaimed(socket: path) else { break }
				if let served = await self.whomItServes(path) {
					self.noteOrphan(served, at: path)
					break
				}
			}
			self?.orphanQuestions[path] = nil
		}
	}

	private func isClaimed(socket path: String) -> Bool {
		registry.list().contains { socketPathForVM($0.name) == path }
			|| hosted.values.contains { $0.identity.socketPath == path }
			|| orphanSockets.values.contains(path)
	}

	private func whomItServes(_ path: String) async -> RPCResults.Hello.Host? {
		if let ask = whomItServesForTesting { return await ask(path) }
		guard let client = try? await RemoteMachman(
			socketPath: path, clientName: "machman-agent-router", helloDeadline: helloDeadline)
		else { return nil }
		await client.disconnect()
		return client.hello.host
	}

	// Places a vmhost that serves `served` on a socket that isn't its VM's (E11): the library
	// entry whose folder it serves answers through it until it exits. A safe run's vmhost
	// names the real VM's folder, whose unsafe disks its run has attached (F23).
	func noteOrphan(_ served: RPCResults.Hello.Host, at path: String) {
		let library = libraryDir()
		let entry = served.vmDir.flatMap { folder in
			registry.list().first { isSameFile(folder, library + "/" + $0.name) }?.name
		}
		guard let entry else {
			MachmanLogger.log(.passiveWarning,
				"the vmhost for \(served.vm) (pid \(served.pid)) serves "
					+ "\(served.vmDir ?? "a deleted folder"), not a VM in the library — "
					+ "leaving it running")
			return
		}
		guard hosted[entry] == nil, orphanSockets[entry] == nil,
			!UDSListener.isLive(path: socketPathForVM(entry)) else { return }
		orphanSockets[entry] = path
		MachmanLogger.log(.passiveWarning,
			"\(entry) still runs as \(served.vm) (pid \(served.pid)) on that name's socket: "
				+ "its folder was renamed while it ran")
		registry.events.emit(.listChanged)
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
			markSafeRun(host, runRoot: runRoot, entry: entry, vm: marker.vm)
			return
		}
	}

	// What both halves do once a run root is proven this host's: the host is a safe run again.
	private func markSafeRun(_ host: HostedVM, runRoot: String, entry: String, vm: String) {
		host.identity.isSafe = true
		host.identity.shadowRoot = runRoot
		MachmanLogger.log(.log, "re-attached safe run \(entry) to \(vm)")
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
				markSafeRun(host, runRoot: runRoot, entry: entry, vm: marker.vm)
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
	// solely because the only caller is start(), which runs under its start claim: a second
	// start of the same name is refused before it can reach this.
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

	// Sockets are only unlinked on an orderly exit, so anything killed leaves one behind — and a
	// leftover for a VM since renamed or deleted would never be probed by adoption, which only
	// looks at VMs that still exist. Sweep the whole runtime dir instead: control sockets
	// (vm-*.sock) and the per-port serial data-plane sockets (tty-*.sock) a crashed vmhost
	// leaves beside them. The dir is injectable so tests can sweep a scratch dir.
	private func pruneDeadHostSockets() {
		pruneDeadHostSockets(dir: machmanRuntimeDir)
	}

	func pruneDeadHostSockets(dir: String) {
		Self.pruneDeadHostSockets(in: dir)
	}

	// The sweep itself, on no actor. A vm-*.sock goes in turn with a vmhost starting on its
	// path (review F13); a tty-*.sock's name carries its run's id, so no starter shares it.
	nonisolated static func pruneDeadHostSockets(in dir: String) {
		guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
			return
		}
		for entry in entries where entry.hasSuffix(".sock") {
			let path = dir + "/" + entry
			if entry.hasPrefix("vm-") {
				guard BoundSocket.removeIfDead(path) == .removed else { continue }
			} else if entry.hasPrefix("tty-") {
				guard !UDSListener.isLive(path: path) else { continue }
				unlink(path)
			} else {
				continue
			}
			MachmanLogger.log(.log, "removed stale vmhost socket \(entry)")
		}
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
}
