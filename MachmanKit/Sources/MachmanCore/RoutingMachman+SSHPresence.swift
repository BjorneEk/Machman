//
//  RoutingMachman+SSHPresence.swift
//  MachmanCore
//
//  The daemon's SSH half: address discovery and sshd readiness for running VMs, the
//  VMInfo overlay that serves them, vm.ssh.set and vm.ssh.reset, and every ~/.ssh write
//  (through the one owner, SSHHostFiles).
//

import Foundation
import MachmanAPI
import MachmanClient

extension RoutingMachman {
	// MARK: - SSH discovery (1.0.5, daemon-side)

	// Host-side access follows the CURRENT key, always. A guest that re-runs the setup
	// script after an uninstall mints a fresh reverse key, which drops approval back to
	// pending — and the line installed for the old key has to go with it, or that key
	// keeps its way in with nothing in the UI offering to revoke it.
	func reconcileReverseKey(vm name: String) {
		guard sshFiles != nil, let marker = existingSSHMarker(name) else { return }
		Task { [weak self] in
			guard let self,
				let ssh = (try? await self.proxy(name).vm(named: name))?.ssh else { return }
			guard ssh.reverseState != .approved else { return }
			self.revokeReverseKey(marker: marker, vmName: name)
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
	//
	// The VM's name is read at every ask and every announcement, never kept: Save as New
	// VM re-keys a running host, and a run that went on under the original's name sent
	// clients to refetch a stopped VM while the saved one's row stayed "waiting" (E42).
	// `probes` is where it looks: the live tables and port 22, or a test's stand-ins.
	func startSSHDiscovery(_ host: HostedVM, probes: SSHDiscovery.Probes = .live) {
		host.sshDiscoveryTask?.cancel()
		guard let mac = host.identity.macInUse else { return }
		let id = host.identity.id
		host.sshReach = .unknown
		host.sshReachDetail = nil
		host.sshReadySince = nil
		host.sshDiscoveryTask = Task { [weak self] in
			let wantsSSH = await self?.guestHasSSH(hostID: id) ?? false
			if wantsSSH, let self, let host = self.host(withID: id) {
				host.sshReach = .waiting
				self.announceSSH(of: host)
			}
			var attempt = 0
			var address: String?
			while !Task.isCancelled, address == nil {
				let answer = await probes.address(mac)
				guard let self, let host = self.host(withID: id) else { return }
				if let answer {
					if host.sshAnswer != answer {
						host.sshAnswer = answer
						self.announceSSH(of: host)
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
			await self?.probeSSHReadiness(id: id, address: address, probes: probes)
		}
	}

	// Whether this run's guest has SSH set up, read from the process that OWNS the config —
	// the vmhost: the daemon's registry copy was parsed at scan time and never sees the
	// guest's first report, which left readiness stuck at "unknown" for exactly the run
	// where the user just ran the script. Asked under the name the host serves now; a host
	// that can't say (its Save as New VM renamed the VM under the ask) is taken at its last
	// answer — the saved VM keeps the run's guest user.
	private func guestHasSSH(hostID id: UUID) async -> Bool {
		guard let host = host(withID: id) else { return false }
		let answer = try? await host.client.vm(named: host.identity.name)
		return (answer ?? self.host(withID: id)?.lastAnswer)?.ssh?.guestUser != nil
	}

	private func announceSSH(of host: HostedVM) {
		registry.events.emit(.sshChanged(vm: host.identity.name))
	}

	// Phase 2. Tight while a guest is still booting, then slower, and bounded: a VM whose
	// sshd never comes up gets an answer ("unreachable", with the reason) instead of a
	// spinner that never stops. vm.ssh.refresh starts the whole thing over — that is what
	// the desktop's retry and session reconnect call.
	private func probeSSHReadiness(
		id: UUID, address: String, probes: SSHDiscovery.Probes
	) async {
		let deadline = Date().addingTimeInterval(180)
		var tries = 0
		while !Task.isCancelled {
			let answered = await probes.sshd(address)
			guard let host = self.host(withID: id) else { return }
			if answered {
				host.sshReach = .ready
				host.sshReachDetail = nil
				host.sshReadySince = Date()
				announceSSH(of: host)
				return
			}
			if Date() >= deadline {
				host.sshReach = .unreachable
				host.sshReachDetail = "no answer on \(address):22 after 3 minutes"
				announceSSH(of: host)
				return
			}
			tries += 1
			try? await Task.sleep(for: tries < 15 ? .seconds(2) : .seconds(5))
		}
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

	// Every guest→Mac grant leaves ~/.ssh/authorized_keys through here: a deleted VM's, a
	// denied or revoked one, a reset, a key the guest replaced. Never silent (D11, C21): a
	// line that stays is logged and shown, with what to remove by hand — a deny that left the
	// key working used to read as done.
	func revokeReverseKey(marker: String, vmName name: String) {
		guard let files = sshFiles else { return }
		do {
			try files.setReverseKey(nil, marker: marker, vmName: name)
		} catch {
			MachmanLogger.log(.passiveWarning, "revoking \(name)'s reverse key: \(error)")
			registry.events.emit(.log(
				vm: name, level: .warning,
				message: "Couldn’t remove the guest’s key from ~/.ssh/authorized_keys — "
					+ "delete the line ending in machman:\(marker):\(name)"))
		}
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
				try requireSSHAliasFree(wanted, for: name)
			}
		}
		let record = {
			try await target.setSSH(
				vm: name, integrationEnabled: integrationEnabled,
				reverseApproved: reverseApproved, alias: alias)
		}
		// The host-side line reads the OWNER's state, never the registry copy — stale while
		// the VM is hosted (setStartPolicy precedent).
		let marker = existingSSHMarker(name)
		let info: VMInfo
		if reverseApproved == true, let marker {
			info = try await approveReverseKey(vm: name, marker: marker, on: target, record: record)
		} else {
			info = try await record()
			if reverseApproved == false, let marker {
				revokeReverseKey(marker: marker, vmName: name)
			}
		}
		scheduleSSHHostConfigWrite()
		return info
	}

	// Whether another VM already answers to `wanted`, from each VM's config ON DISK (C24): a
	// hosted VM's vmhost saves the alias it takes there, while the daemon's copy predates the
	// run. The registry copy speaks only for a VM with no config there. Internal so tests can
	// run it under the redirect lock.
	func requireSSHAliasFree(_ wanted: String, for name: String) throws {
		let onDisk = Dictionary(
			SSHAliasAssignment.claims(inLibrary: machmanVMDir).map { ($0.name, $0) },
			uniquingKeysWith: { first, _ in first })
		for other in registry.list() where other.name != name {
			let alias = onDisk[other.name].map { $0.stored ?? other.config.resolvedDefaultAlias }
				?? other.config.effectiveSSHAlias
			guard alias == wanted else { continue }
			throw MachmanError(
				code: .invalidArgument,
				message: "\(other.name) already answers to \u{201C}\(wanted)\u{201D}")
		}
	}

	// Approving guest→Mac access (C21). The key line goes in first: a Mac that refuses it
	// refuses the approval, and nothing is recorded — the toggle used to say approved with no
	// line installed. Then `record` saves the approval with the config's owner, and a record
	// that fails takes the line back out. Internal so tests can drive it against a stub owner.
	func approveReverseKey(
		vm name: String, marker: String, on target: MachmanControlling,
		record: () async throws -> VMInfo
	) async throws -> VMInfo {
		// No key reported: nothing to install, and the owner refuses the approval itself.
		guard let files = sshFiles,
			let key = try await target.vm(named: name).ssh?.reversePublicKey
		else { return try await record() }
		try files.setReverseKey(key, marker: marker, vmName: name)
		let info: VMInfo
		do {
			info = try await record()
		} catch {
			revokeReverseKey(marker: marker, vmName: name)
			throw error
		}
		// A report that replaced the key during the call: the line follows what was approved.
		if let approved = info.ssh?.reversePublicKey, approved != key {
			do {
				try files.setReverseKey(approved, marker: marker, vmName: name)
			} catch {
				revokeReverseKey(marker: marker, vmName: name)
				throw error
			}
		}
		return info
	}

	public func resetSSH(vm name: String) async throws -> VMInfo {
		let target = try await settingsOwner(name)
		try refuseSSHWhileSafe(name)
		let marker = existingSSHMarker(name)
		let info = try await target.resetSSH(vm: name)
		if let marker {
			revokeReverseKey(marker: marker, vmName: name)
		}
		scheduleSSHHostConfigWrite()
		return info
	}

	// The marker labeling this VM's host-side artifacts — a read-only derivation from
	// the identity file, safe against the stale-while-hosted registry copy (paths only).
	func existingSSHMarker(_ name: String) -> String? {
		guard let config = registry.vm(named: name)?.config else { return nil }
		return SSHSetupInstaller.existingMarker(for: config)
	}

	// Rebuild ~/.ssh/machman/config (+ Include line) from current state. The owner runs one
	// pass at a time and gathers again for requests made meanwhile, so the newest state is
	// the one that lands.
	func scheduleSSHHostConfigWrite() {
		sshFiles?.regenerate { [weak self] in await self?.sshHostEntries() }
	}

	// One entry per VM with the ~/.ssh integration on, from current state. The vmhosts are
	// asked at once (a stalled one costs the pass one deadline, never one per host), and a
	// VM whose host can't answer keeps its entry from what the daemon last knew.
	private func sshHostEntries() async -> [SSHHostConfigWriter.VMEntry] {
		let vms = registry.list()
		var asks: [String: Task<VMInfo?, Never>] = [:]
		for vm in vms {
			guard let host = hosted[vm.name], !host.identity.isSafe else { continue }
			asks[vm.name] = Task { await self.sshState(of: host) }
		}
		var entries: [SSHHostConfigWriter.VMEntry] = []
		for vm in vms {
			let name = vm.name
			let info: VMInfo?
			if let ask = asks[name] {
				info = await ask.value
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
		return entries
	}

	// A hosted VM's state with the daemon's overlay. The vmhost's answer is the fresh state
	// (the registry copy predates the run), bounded like a list probe; a host that is Not
	// responding or misses the deadline gives its last answer, else the registry copy — a
	// dropped answer used to drop the VM's alias and pinned key from ~/.ssh.
	private func sshState(of host: HostedVM) async -> VMInfo? {
		let name = host.identity.name
		var info: VMInfo?
		if !host.unresponsive {
			info = try? await host.client.vm(named: name, deadline: hostProbeDeadline)
		}
		if info == nil { info = host.lastAnswer }
		if info == nil { info = try? await local.vm(named: name) }
		guard var found = info else { return nil }
		overlaySSH(&found, from: host)
		return found
	}
}
