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
			guard let self, let owner = try? await self.proxy(name) else { return }
			await self.reconcileReverseKey(vm: name, marker: marker, owner: owner)
		}
	}

	// The owner's state decides. A line can be there only for a key on file, or for one this
	// daemon saw approved (an uninstall forgets the key, not the line): only for those is an
	// unreadable authorized_keys worth saying — it runs at every report of every VM. The
	// others are reconciled too, which costs a read when the file has no line of theirs.
	// Internal so tests can drive it against a stub owner.
	func reconcileReverseKey(vm name: String, marker: String, owner: MachmanControlling) async {
		guard let files = sshFiles, let ssh = (try? await owner.vm(named: name))?.ssh else {
			return
		}
		if ssh.reverseState == .approved {
			files.noteGranted(marker)
			return
		}
		revokeReverseKey(
			marker: marker, vmName: name,
			announce: .oncePerVM(lineMayExist: ssh.reversePublicKey != nil
				|| files.wasGranted(marker)))
	}

	// Bounded per-VM resolver in two phases, on one task keyed by identity.id (so
	// safe-save re-keying can't cross wires) and cancelled in hostGone:
	//
	//   1. the address — 5 s cadence while DHCP settles (2 min), then once a minute for
	//      as long as the VM stays hosted and unresolved. The address is a fact of the
	//      running VM whether or not anything listens on it, so nothing gates it. Bounded
	//      like phase 2 for a VM with SSH set up (E57): once the settle window is spent it
	//      reads unreachable with the reason, and an address found later moves it on.
	//   2. reachability — does the guest's sshd actually answer? Only for VMs whose guest
	//      has run the setup script (without a reported user there is nothing to connect
	//      as, and "waiting for SSH" would be noise on every other VM).
	//
	// The VM's name is read at every ask and every announcement, never kept: Save as New
	// VM re-keys a running host, and a run that went on under the original's name sent
	// clients to refetch a stopped VM while the saved one's row stayed "waiting" (E42).
	// `probes` is where it looks: the live tables, what the guest's reports taught the VM's
	// config (E56) and port 22, or a test's stand-ins.
	func startSSHDiscovery(
		_ host: HostedVM, probes: SSHDiscovery.Probes = .live, pace: DiscoveryPace = .live
	) {
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
			var gaveUp = false
			while !Task.isCancelled, address == nil {
				guard let name = self?.host(withID: id)?.identity.name else { return }
				let answer = await probes.address(SSHDiscovery.Lookup(
					mac: mac, vm: name, library: machmanVMDir,
					taken: self?.answeredByOthers(than: id) ?? []))
				// A restart cancelled this pass during the ask: the host is the new pass's now.
				guard !Task.isCancelled, let self, let host = self.host(withID: id) else { return }
				if let answer {
					if gaveUp {
						// An address after all: back to waiting, for phase 2 to answer.
						host.sshReach = .waiting
						host.sshReachDetail = nil
					}
					if host.sshAnswer != answer {
						host.sshAnswer = answer
						self.announceSSH(of: host)
						// The alias's HostName just became known/changed.
						self.scheduleSSHHostConfigWrite()
					} else if gaveUp {
						self.announceSSH(of: host)
					}
					address = answer.address
					break
				}
				attempt += 1
				if wantsSSH, !gaveUp, attempt >= pace.fastTries {
					gaveUp = true
					host.sshReach = .unreachable
					host.sshReachDetail =
						"no address for \(mac) in the DHCP leases or the ARP table"
					self.announceSSH(of: host)
				}
				try? await Task.sleep(for: attempt < pace.fastTries ? pace.fast : pace.slow)
			}
			guard wantsSSH, let address else { return }
			await self?.probeSSHReadiness(id: id, address: address, probes: probes)
		}
	}

	// The config's owner ingested a guest report (its sshChanged). Discovery starts over when it
	// has no address yet, or never watched readiness (reach .unknown: the guest had not run
	// the script when this run started) — a fresh report can mean sshd just appeared. Any
	// other answer is asked again, since a report can teach what moves it: a client id or an
	// address that replaces a stale report's (review F5), or a client id that shows an ARP
	// entry stale (review F12). When the lookup now lands elsewhere, discovery starts over; a
	// lookup that finds nothing leaves the answer be (an ARP entry ages out after about 20
	// idle minutes while the guest stays where it was — review F19).
	func sshReportArrived(_ host: HostedVM, probes: SSHDiscovery.Probes = .live) {
		guard let answer = host.sshAnswer, host.sshReach != .unknown else {
			startSSHDiscovery(host, probes: probes)
			return
		}
		guard let mac = host.identity.macInUse else { return }
		let id = host.identity.id
		let lookup = SSHDiscovery.Lookup(
			mac: mac, vm: host.identity.name, library: machmanVMDir,
			taken: answeredByOthers(than: id))
		Task { [weak self] in
			let now = await probes.address(lookup)
			guard let self, let host = self.host(withID: id), host.sshAnswer == answer,
				let now, now.address != answer.address else { return }
			self.startSSHDiscovery(host, probes: probes)
		}
	}

	// The addresses the other hosted VMs answer now: discovery's hints never take one (F8).
	private func answeredByOthers(than id: UUID) -> Set<String> {
		Set(hosted.values.filter { $0.identity.id != id }.compactMap { $0.sshAnswer?.address })
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

	// Phase 1's pace: `fastTries` asks `fast` apart while DHCP settles — the window after
	// which a VM with SSH set up reads unreachable — then one every `slow`.
	struct DiscoveryPace: Sendable {
		var fast: Duration
		var fastTries: Int
		var slow: Duration

		static let live = DiscoveryPace(fast: .seconds(5), fastTries: 24, slow: .seconds(60))
	}

	private func announceSSH(of host: HostedVM) {
		registry.events.emit(.sshChanged(vm: host.identity.name))
	}

	// How long the readiness probe tries before it says "unreachable": three minutes, unless
	// a lab run sets MACHMAN_LAB_SSH_READY_SECONDS (test mode only). The detail text keeps
	// saying three minutes either way.
	nonisolated static func sshReadyDeadline(lab: LabEnvironment? = .current) -> TimeInterval {
		lab?.seconds("MACHMAN_LAB_SSH_READY_SECONDS") ?? 180
	}

	// Phase 2. Tight while a guest is still booting, then slower, and bounded: a VM whose
	// sshd never comes up gets an answer ("unreachable", with the reason) instead of a
	// spinner that never stops. vm.ssh.refresh starts the whole thing over — that is what
	// the desktop's retry and session reconnect call.
	private func probeSSHReadiness(
		id: UUID, address: String, probes: SSHDiscovery.Probes
	) async {
		let deadline = Date().addingTimeInterval(Self.sshReadyDeadline())
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

	// How a removal that fails is said.
	enum GrantNotice {
		// Something the user did — Deny, Revoke, Reset SSH State, deleting the VM, an approval
		// rolled back: every time, naming the line to remove (a deleted VM's marker can't be
		// found afterwards).
		case always
		// The reconcile at every report: once per VM until its line is gone, and an unreadable
		// file only for a VM that can have a line at all.
		case oncePerVM(lineMayExist: Bool)
	}

	// Every guest→Mac grant leaves ~/.ssh/authorized_keys through here: a deleted VM's, a
	// denied or revoked one, a reset, a key the guest replaced. Never silent (D11, C21): a
	// line that stays is logged and shown, with what to remove by hand — a deny that left the
	// key working used to read as done.
	func revokeReverseKey(marker: String, vmName name: String, announce: GrantNotice) {
		guard let files = sshFiles else { return }
		let line = "delete the line ending in machman:\(marker):\(name)"
		let present: Bool
		do {
			present = try files.hasReverseKey(marker: marker)
		} catch {
			MachmanLogger.log(.passiveWarning, "reading authorized_keys for \(name): \(error)")
			let message: String
			switch announce {
			case .always:
				message = "Couldn’t read ~/.ssh/authorized_keys — " + line
			case .oncePerVM(let lineMayExist):
				guard lineMayExist, files.firstWarning(for: marker) else { return }
				message = "Couldn’t read ~/.ssh/authorized_keys to remove the guest’s key"
			}
			registry.events.emit(.log(vm: name, level: .warning, message: message))
			return
		}
		do {
			if present {
				try files.setReverseKey(nil, marker: marker, vmName: name)
			}
			files.lineGone(marker)
		} catch {
			MachmanLogger.log(.passiveWarning, "revoking \(name)'s reverse key: \(error)")
			if case .oncePerVM = announce, !files.firstWarning(for: marker) { return }
			registry.events.emit(.log(
				vm: name, level: .warning,
				message: "Couldn’t remove the guest’s key from ~/.ssh/authorized_keys — " + line))
		}
	}

	// MARK: - SSH (1.0.5)

	// Config-plane like devices, but with daemon-side ~/.ssh effects — refuse during safe
	// runs (setStartPolicy reasoning: host-side state must never reconcile against a
	// discardable shadow write).
	private func refuseSSHWhileSafe(_ name: String) throws {
		try refuseWhileSafe(name, "SSH settings")
	}

	public func setSSH(
		vm name: String, integrationEnabled: Bool?, reverseApproved: Bool?, alias: String?
	) async throws -> VMInfo {
		// Resolved first: reaching the owner can adopt a host, and with it a safe run.
		let info = try await editSettings(name) { target -> VMInfo in
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
			// The host-side line reads the OWNER's state, never the registry copy — stale
			// while the VM is hosted (setStartPolicy precedent).
			let marker = existingSSHMarker(name)
			if reverseApproved == true, let marker {
				return try await approveReverseKey(
					vm: name, marker: marker, on: target, record: record)
			}
			let info = try await record()
			if reverseApproved == false, let marker {
				revokeReverseKey(marker: marker, vmName: name, announce: .always)
			}
			return info
		}
		await writeSSHHostConfig()
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
			// Case folded (C31): ssh keys the host-key pin by the lowercased alias.
			guard alias.lowercased() == wanted.lowercased() else { continue }
			throw MachmanError(
				code: .invalidArgument,
				message: "\(other.name) already answers to \u{201C}\(alias)\u{201D}")
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
			revokeReverseKey(marker: marker, vmName: name, announce: .always)
			throw error
		}
		// A report that replaced the key during the call: the line follows what was approved.
		if let approved = info.ssh?.reversePublicKey, approved != key {
			do {
				try files.setReverseKey(approved, marker: marker, vmName: name)
			} catch {
				revokeReverseKey(marker: marker, vmName: name, announce: .always)
				throw error
			}
		}
		files.noteGranted(marker)
		return info
	}

	public func resetSSH(vm name: String) async throws -> VMInfo {
		let info = try await editSettings(name) { target -> VMInfo in
			try refuseSSHWhileSafe(name)
			let marker = existingSSHMarker(name)
			let info = try await target.resetSSH(vm: name)
			if let marker {
				revokeReverseKey(marker: marker, vmName: name, announce: .always)
			}
			return info
		}
		await writeSSHHostConfig()
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

	// The same, for a request whose reply says the change is made: vm.ssh.set and reset
	// answer once ~/.ssh says what they set, so `ssh <alias>` right after the reply works —
	// a client that ran it at once found no managed config yet.
	private func writeSSHHostConfig() async {
		scheduleSSHHostConfigWrite()
		await sshFiles?.settled()
	}

	// One entry per VM with the ~/.ssh integration on, from current state. The vmhosts are
	// asked at once (a stalled one costs the pass one deadline, never one per host), and a
	// VM whose host can't answer keeps its entry from what the daemon last knew.
	private func sshHostEntries() async -> [SSHHostConfigWriter.VMEntry] {
		let vms = registry.list()
		var running: [String: HostedVM] = [:]
		for vm in vms {
			guard let host = hosted[vm.name], !host.identity.isSafe else { continue }
			running[vm.name] = host
		}
		let deadline = hostProbeDeadline
		let answers = await fanOut(to: running, skippingUnresponsive: true) { name, host in
			try? await host.client.vm(named: name, deadline: deadline)
		}
		var entries: [SSHHostConfigWriter.VMEntry] = []
		for vm in vms {
			let name = vm.name
			let info: VMInfo?
			if let host = running[name] {
				info = await sshState(of: host, answer: answers[name] ?? nil)
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
	// (the registry copy predates the run), asked like a list probe; a host that is Not
	// responding or missed the deadline gives its last answer, else the registry copy — a
	// dropped answer used to drop the VM's alias and pinned key from ~/.ssh.
	private func sshState(of host: HostedVM, answer: VMInfo?) async -> VMInfo? {
		let name = host.identity.name
		var info = answer
		if info == nil { info = host.lastAnswer }
		if info == nil { info = try? await local.vm(named: name) }
		guard var found = info else { return nil }
		overlaySSH(&found, from: host)
		return found
	}
}
