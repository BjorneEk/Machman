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
		guard let files = sshFiles, let marker = existingSSHMarker(name) else { return }
		Task { [weak self] in
			guard let self,
				let ssh = (try? await self.proxy(name).vm(named: name))?.ssh else { return }
			guard ssh.reverseState != .approved else { return }
			try? files.setReverseKey(nil, marker: marker, vmName: name)
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

	// A deleted VM's guest→Mac grant leaves ~/.ssh/authorized_keys. Best-effort by nature —
	// the VM is gone, and the key's private half with it — but never silent (D11): a line
	// that stays is logged and shown, with what to remove by hand.
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
		if let files = sshFiles, let reverseApproved,
			let marker = existingSSHMarker(name) {
			try? files.setReverseKey(
				reverseApproved ? info.ssh?.reversePublicKey : nil,
				marker: marker, vmName: name)
		}
		scheduleSSHHostConfigWrite()
		return info
	}

	public func resetSSH(vm name: String) async throws -> VMInfo {
		let target = try await settingsOwner(name)
		try refuseSSHWhileSafe(name)
		let marker = existingSSHMarker(name)
		let info = try await target.resetSSH(vm: name)
		if let files = sshFiles, let marker {
			try? files.setReverseKey(nil, marker: marker, vmName: name)
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

	// One entry per VM with the ~/.ssh integration on, from current state.
	private func sshHostEntries() async -> [SSHHostConfigWriter.VMEntry] {
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
		return entries
	}
}
