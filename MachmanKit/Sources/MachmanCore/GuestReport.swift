//
//  GuestReport.swift
//  MachmanCore
//
//  The guest's setup report: flat key=value lines written into the writable GuestReport
//  drop-box by the generated script. The drop-box is guest-writable, so the parser is
//  deliberately defensive — size-capped, whitelist-keyed (exact keys plus the numbered/
//  named section prefixes), garbage-tolerant — and apply() treats values as claims, not
//  truth (the daemon's own discovery cross-checks the address; host keys only pin the
//  guest's own identity). The claims that reach ~/.ssh — user, address, host and reverse
//  keys — are shape-checked first (GuestValueRule): a refused value leaves the stored one.
//  Ingested by the process that owns the config (the vmhost while running); the HOST
//  stamps the ingestion time. Two halves: the SSH keys the v2 script already wrote
//  (applied into config.ssh, byte-compatible), and the v3 setup sections
//  (FEATURE_/CONSOLE_/AUTOMOUNT_/ERROR_/NOTE_) applied into config.setup as a whole snapshot.
//

import Foundation
import MachmanAPI

struct GuestReport {
	var values: [String: String]
	// Found by the host beside the report, never one of its claims: the DHCP client id of the
	// lease that holds the address the guest reported (E56).
	var leaseClientID: String?

	// Which halves an apply() actually moved — the caller emits per-half events.
	struct Changes {
		var ssh = false
		var setup = false
		var any: Bool { ssh || setup }
	}

	// A report is a handful of short lines; anything bigger is not our file.
	static let maxBytes = 64 * 1024
	static let maxValueLength = 8 * 1024
	// A hostile guest could fill the 64 KB with section lines; nothing legitimate has
	// more than a handful per section.
	static let maxSectionEntries = 64
	// Whitelist: the keys apply() reads, so a v2 report still applies to a v3 daemon and any
	// other key is ignored rather than fatal — a future report's extras, and the keys the
	// script writes that nothing here reads (HOME, GATEWAY, TWO_WAY, SSHD, SSHFS_VERSION,
	// FAILED_STEPS, KERNEL_CONSOLE, KERNEL_CONSOLE_METHOD).
	static let allowedKeys: Set<String> = [
		"SCRIPT_VERSION", "SCRIPT_CKSUM", "MARKER", "OS_ID", "USER", "HOSTNAME",
		"IP", "HOST_KEY", "REVERSE_PUBKEY", "UNINSTALLED",
		// 1.0.6: what the run achieved, how it got here, and what the guest can do.
		"STATUS", "NOTE", "TRANSPORT", "OS_FAMILY", "OS_VERSION", "INIT",
		"SSHFS", "SSHFS_MOUNT_OK", "SSHFS_MOUNTROOT",
	]
	// Section keys: FEATURE_<wire id>, and CONSOLE_/AUTOMOUNT_/ERROR_/NOTE_<n> (NOTE_<n>:
	// informational lines; the exact key NOTE is the run's one-sentence summary).
	static let allowedPrefixes = ["FEATURE_", "CONSOLE_", "AUTOMOUNT_", "ERROR_", "NOTE_"]

	// What one poll of the drop-box found: the file's mtime, and its report — nil when the
	// file is not one read() takes (so it is not read again until it changes).
	struct Found {
		let mtime: Date
		let report: GuestReport?
	}

	// nil when there is no report file, or its mtime is still `since`. A new report that names
	// an address gets the client id of the lease holding it: bootpd granted that lease just
	// before the guest wrote the report, so its holder is this guest (E56) — when the report
	// is no older than `notBefore` (the run's start): an older one is a crashed run's, and
	// its address may be another guest's lease by now. `leases` is the lease table's text (a
	// test passes its own).
	static func poll(
		atPath path: String, since: Date?, notBefore: Date? = nil,
		leases: () -> String? = { SSHDiscovery.leases(atPath: SSHDiscovery.leasesPath) }
	) -> Found? {
		var info = stat()
		guard lstat(path, &info) == 0 else { return nil }
		let mtime = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
			+ TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
		guard mtime != since else { return nil }
		var report = read(atPath: path)
		if notBefore.map({ mtime >= $0 }) ?? true, let ip = report?.values["IP"],
			GuestValueRule.isAddress(ip), let table = leases() {
			report?.leaseClientID = SSHDiscovery.clientID(holding: ip, inLeasesText: table)
		}
		return Found(mtime: mtime, report: report)
	}

	// The drop-box is guest-writable, so the name is trusted for nothing: a regular file
	// within the cap by lstat, opened without following a link (O_NOFOLLOW) or waiting on a
	// FIFO's writer (O_NONBLOCK), checked again on the descriptor, and never read past
	// maxBytes + 1 — a file swapped or grown after the checks still cannot make it read more.
	static func read(atPath path: String) -> GuestReport? {
		var info = stat()
		guard lstat(path, &info) == 0, isReadable(info) else { return nil }
		let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
		guard fd >= 0 else { return nil }
		defer { close(fd) }
		guard fstat(fd, &info) == 0, isReadable(info) else { return nil }
		var data = Data(count: maxBytes + 1)
		var filled = 0
		while filled < data.count {
			let count = data.withUnsafeMutableBytes { buffer in
				Darwin.read(fd, buffer.baseAddress! + filled, buffer.count - filled)
			}
			if count > 0 {
				filled += count
			} else if count < 0, errno == EINTR {
				continue
			} else {
				break
			}
		}
		guard filled > 0, filled <= maxBytes else { return nil }
		return parse(String(decoding: data.prefix(filled), as: UTF8.self))
	}

	private static func isReadable(_ info: stat) -> Bool {
		(info.st_mode & S_IFMT) == S_IFREG && info.st_size > 0 && info.st_size <= maxBytes
	}

	static func parse(_ text: String) -> GuestReport {
		var values: [String: String] = [:]
		// components(separatedBy: .newlines), not split(separator: "\n") — Swift folds
		// CRLF into ONE Character, so a "\n" split walks straight past CRLF endings.
		for rawLine in text.components(separatedBy: .newlines) {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			guard !line.isEmpty, !line.hasPrefix("#") else { continue }
			guard let eq = line.firstIndex(of: "=") else { continue }
			let key = String(line[..<eq])
			guard allowedKeys.contains(key)
				|| allowedPrefixes.contains(where: { key.hasPrefix($0) && key.count > $0.count })
			else { continue }
			let value = String(line[line.index(after: eq)...])
				.trimmingCharacters(in: .whitespaces)
			guard value.count <= maxValueLength else { continue }
			values[key] = value   // last occurrence wins
		}
		return GuestReport(values: values)
	}

	// MARK: - Section extraction

	// Numbered section values (CONSOLE_1, CONSOLE_2, …) in index order, capped.
	private func numbered(_ prefix: String) -> [String] {
		values.keys
			.compactMap { key -> (Int, String)? in
				guard key.hasPrefix(prefix), let n = Int(key.dropFirst(prefix.count)),
					(1...Self.maxSectionEntries).contains(n) else { return nil }
				return (n, values[key] ?? "")
			}
			.sorted { $0.0 < $1.0 }
			.map(\.1)
	}

	// FEATURE_<id>=<state> <detail…>, state ∈ unavailable|available|configured.
	private func features() -> [GuestFeatureInfo] {
		values.keys
			.filter { $0.hasPrefix("FEATURE_") }
			.sorted()
			.prefix(Self.maxSectionEntries)
			.compactMap { key in
				let id = String(key.dropFirst("FEATURE_".count))
				guard !id.isEmpty, let value = values[key] else { return nil }
				let parts = value.split(separator: " ", maxSplits: 1)
				let state = parts.first.map(String.init) ?? ""
				let detail = parts.count > 1 ? String(parts[1]) : nil
				switch state {
				case "configured":
					return GuestFeatureInfo(
						id: id, available: true, configured: true, detail: detail)
				case "available":
					return GuestFeatureInfo(
						id: id, available: true, configured: false, detail: detail)
				case "unavailable":
					return GuestFeatureInfo(
						id: id, available: false, reason: detail, configured: false)
				default:
					return nil
				}
			}
	}

	// CONSOLE_<n>=<device> <login> [auto] [external] [kernel|kernel-next]
	private func consoles() -> [GuestConsoleInfo] {
		numbered("CONSOLE_").compactMap { value in
			let words = value.split(separator: " ").map(String.init)
			guard words.count >= 2 else { return nil }
			var login = words[1]
			let flags = words.dropFirst(2)
			if flags.contains("auto") {
				login = GuestConsoleLogin.activeAuto
			}
			return GuestConsoleInfo(
				device: words[0], login: login,
				kernelConsole: flags.contains("kernel") ? true : nil,
				kernelConsolePending: flags.contains("kernel-next") ? true : nil,
				external: flags.contains("external") ? true : nil)
		}
	}

	// AUTOMOUNT_<n>=<kind> <target> <path with spaces allowed> — or, when the target (a mount
	// name) has a space, <kind>TAB<target>TAB<path>: a script that sends that row sends TABs
	// only there, so every older row still splits at its first two spaces.
	private func automounts() -> [GuestAutomountInfo] {
		numbered("AUTOMOUNT_").compactMap { value in
			let separator: Character = value.contains("\t") ? "\t" : " "
			let words = value.split(separator: separator, maxSplits: 2).map(String.init)
			guard words.count == 3 else { return nil }
			return GuestAutomountInfo(kind: words[0], target: words[1], path: words[2])
		}
	}

	// ERROR_<n>=<step>: <message>
	private func errors() -> [GuestSetupError] {
		stepLines("ERROR_")
	}

	// NOTE_<n>=<step>: <message> — informational, never a failure.
	private func notes() -> [GuestSetupNote] {
		stepLines("NOTE_")
	}

	// <prefix><n>=<step>: <message>; a line without a step keeps it all as the message.
	private func stepLines(_ prefix: String) -> [GuestSetupError] {
		numbered(prefix).map { value in
			if let colon = value.firstIndex(of: ":") {
				return GuestSetupError(
					step: String(value[..<colon]),
					message: String(value[value.index(after: colon)...])
						.trimmingCharacters(in: .whitespaces))
			}
			return GuestSetupError(step: "", message: value)
		}
	}

	// MARK: - Application

	// A reported value that has the shape it claims; nil when absent or empty, and logged
	// when it is something else (USER=a b, IP=evil.example, command="…" keys).
	private func shaped(
		_ key: String, _ isValid: (String) -> Bool, _ what: String, vm config: VMConfig
	) -> String? {
		guard let value = values[key], !value.isEmpty else { return nil }
		guard isValid(value) else {
			MachmanLogger.log(.log,
				"\(config.name): ignored the guest's reported \(key) — not a \(what)")
			return nil
		}
		return value
	}

	// Fold the report into the persisted state. Caller saves-and-emits per changed half;
	// .any false = nothing changed (identical report re-read).
	@discardableResult
	func apply(to config: VMConfig, stampedAt: Date) throws -> Changes {
		// PR4/C7: every script writes the MARKER of the identity it was served for. A report
		// naming another identity is not this VM's — a source VM's crash leftover, or a
		// cloned guest's boot hook still running the source's script — and must not restamp
		// this VM's hostname, host key or address. Only a MISMATCH drops it: no script omits
		// the key, and the marker is no secret (it rides machman.env into a guest-writable
		// share), so this is a provenance check, not a trust boundary.
		if let reported = values["MARKER"], !reported.isEmpty,
			reported != SSHSetupInstaller.existingMarker(for: config) {
			MachmanLogger.log(.log,
				"\(config.name): ignored a guest report written for another VM (\(reported))")
			return Changes()
		}
		var changes = Changes()
		var state = config.ssh ?? SSHConfig()
		let beforeSSH = state
		if values["UNINSTALLED"] == "1" {
			// The guest removed our artifacts: forget what the report taught us; the
			// user's switches, the alias and the marker stay.
			state.guestUser = nil
			state.guestHostname = nil
			state.guestOS = nil
			state.guestOSVersion = nil
			state.guestHostKey = nil
			state.reversePublicKey = nil
			state.reverseState = SSHInfo.ReverseState.none.rawValue
			state.sshfsAvailable = nil
			state.sshfsMountReady = nil
			state.sshfsMountRoot = nil
			state.lastRunStatus = nil
			state.lastRunNote = nil
			state.lastTransport = nil
		} else {
			if let user = shaped("USER", GuestValueRule.isUserName, "user name", vm: config) {
				state.guestUser = user
			}
			if let host = values["HOSTNAME"], !host.isEmpty { state.guestHostname = host }
			if let os = values["OS_ID"], !os.isEmpty { state.guestOS = os }
			if let version = values["OS_VERSION"], !version.isEmpty {
				state.guestOSVersion = version
			}
			if let key = shaped("HOST_KEY", GuestValueRule.isPublicKeyLine, "public key",
				vm: config) {
				state.guestHostKey = key
			}
			// The address is a claim (the drop-box is guest-writable), kept as the fallback
			// that survives a rename, with the client id its lease is kept under — the
			// daemon's discovery checks both against the lease table (E56).
			if let ip = shaped("IP", GuestValueRule.isAddress, "IP address", vm: config) {
				state.lastAddress = ip
				if let leaseClientID { state.dhcpClientID = leaseClientID }
			}
			// What the run achieved. A v1 report carries none of this: absence means
			// "an older script ran", not "it failed", so nothing is cleared here.
			if let status = values["STATUS"], !status.isEmpty { state.lastRunStatus = status }
			if let note = values["NOTE"], !note.isEmpty { state.lastRunNote = note }
			if let transport = values["TRANSPORT"], !transport.isEmpty {
				state.lastTransport = transport
			}
			if let version = values["SCRIPT_VERSION"], let number = Int(version) {
				state.scriptVersion = number
			}
			if let sshfs = values["SSHFS"] {
				state.sshfsAvailable = sshfs == "1"
				state.sshfsMountReady = values["SSHFS_MOUNT_OK"] == "1"
				let root = values["SSHFS_MOUNTROOT"] ?? ""
				state.sshfsMountRoot = root.isEmpty ? nil : root
			}
			if let reverse = shaped("REVERSE_PUBKEY", GuestValueRule.isPublicKeyLine,
				"public key", vm: config) {
				if state.reversePublicKey != reverse {
					// A new key always needs fresh approval — even if one was approved.
					state.reversePublicKey = reverse
					state.reverseState = SSHInfo.ReverseState.pending.rawValue
				} else if state.reverseStateValue == .none {
					state.reverseState = SSHInfo.ReverseState.pending.rawValue
				}
			}
		}
		changes.ssh = state != beforeSSH

		// The setup half: a v3 report is a whole snapshot — sections REPLACE, so a clean
		// run clears a partial one's errors. A v2 report (script < 3, no sections) leaves
		// setup alone entirely: an older script ran, it has nothing to say here.
		let scriptVersion = values["SCRIPT_VERSION"].flatMap(Int.init)
		let isV3 = (scriptVersion ?? 0) >= 3
			|| values.keys.contains { key in
				Self.allowedPrefixes.contains { key.hasPrefix($0) }
			}
		if values["UNINSTALLED"] == "1" {
			if var setup = config.setup {
				let before = setup
				setup.installed = false
				setup.lastRunStatus = nil
				setup.lastRunNote = nil
				setup.errors = []
				setup.notes = []
				setup.features = []
				setup.consoles = []
				setup.automounts = []
				if setup != before {
					setup.lastReportAt = stampedAt
					config.setup = setup
					changes.setup = true
				}
			}
			// Uninstalled = the guest forgot Machman; the names it gave go with it.
			for index in config.consolePorts.indices
				where config.consolePorts[index].guestName != nil {
				config.consolePorts[index].guestName = nil
				changes.setup = true
			}
		} else if isV3 {
			var setup = config.setup ?? GuestSetupConfig()
			let before = setup
			setup.installed = true
			// The guest's identity updates when reported, never blanks when omitted…
			if let os = values["OS_ID"], !os.isEmpty { setup.guestOS = os }
			if let family = values["OS_FAMILY"], !family.isEmpty {
				setup.guestOSFamily = family
			}
			if let version = values["OS_VERSION"], !version.isEmpty {
				setup.guestOSVersion = version
			}
			if let initSystem = values["INIT"], !initSystem.isEmpty {
				setup.guestInit = initSystem
			}
			if let scriptVersion { setup.scriptVersion = scriptVersion }
			// v8: the running script's POSIX cksum ("<crc> <length>"), kept as reported.
			if let cksum = values["SCRIPT_CKSUM"],
				cksum.range(of: #"^[0-9]{1,10} [0-9]{1,12}$"#, options: .regularExpression) != nil {
				setup.scriptCksum = cksum
			}
			// …while the RUN is a whole snapshot: a clean run replaces a partial one's
			// status, errors and sections instead of accumulating them.
			setup.lastRunStatus = values["STATUS"]
			setup.lastRunNote = values["NOTE"]
			setup.lastTransport = values["TRANSPORT"]
			setup.errors = errors()
			setup.notes = notes()
			setup.features = features()
			setup.consoles = consoles()
			setup.automounts = automounts()
			if setup != before {
				setup.lastReportAt = stampedAt
				config.setup = setup
				changes.setup = true
			}
			// The guest's own device names become the ports' names. CONSOLE_N lines are
			// emitted in enabled-compacted order — exactly the numbering the guest sees —
			// so the k-th reported console names the k-th ENABLED port. A shorter report
			// never blanks an existing name: a name is identity, absence isn't denial.
			// Tracked separately from the snapshot so the save + event still fire when
			// the setup content is byte-equal (a re-read of an already-ingested report
			// on a build that only now persists names).
			let reported = setup.consoles
			var enabledSeen = 0
			for index in config.consolePorts.indices where config.consolePorts[index].enabled {
				defer { enabledSeen += 1 }
				guard enabledSeen < reported.count else { break }
				let name = reported[enabledSeen].device
				if !name.isEmpty, config.consolePorts[index].guestName != name {
					config.consolePorts[index].guestName = name
					changes.setup = true
				}
			}
		}

		guard changes.any else { return changes }
		if changes.ssh {
			state.lastReportAt = stampedAt
			config.ssh = state
		}
		try config.saveVMConfig()
		// The guest just told us its identity: pin it where the session tabs look, so a
		// tab verifies the guest without touching the user's own ~/.ssh/known_hosts.
		if changes.ssh {
			SSHSetupInstaller.writeKnownHosts(for: config)
		}
		return changes
	}
}
