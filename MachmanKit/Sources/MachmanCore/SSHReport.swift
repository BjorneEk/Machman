//
//  SSHReport.swift
//  MachmanCore
//
//  The guest's SSH setup report: flat key=value lines written into the writable SSHReport
//  drop-box by the generated script. The drop-box is guest-writable, so the parser is
//  deliberately defensive — size-capped, whitelist-keyed, garbage-tolerant — and apply()
//  treats values as claims, not truth (the daemon's own discovery cross-checks the
//  address; host keys only pin the guest's own identity). Ingested by the process that
//  owns the config (the vmhost while running); the HOST stamps the ingestion time.
//

import Foundation
import MachmanAPI

struct SSHReport {
	var values: [String: String]

	// A report is a handful of short lines; anything bigger is not our file.
	static let maxBytes = 64 * 1024
	static let maxValueLength = 8 * 1024
	// Whitelist, so a v1 report still applies to a v2 daemon and a future report's extra
	// keys are ignored rather than fatal.
	static let allowedKeys: Set<String> = [
		"SCRIPT_VERSION", "MARKER", "OS_ID", "USER", "HOME", "HOSTNAME",
		"IP", "GATEWAY", "TWO_WAY", "HOST_KEY", "REVERSE_PUBKEY", "UNINSTALLED",
		// 1.0.6: what the run achieved, how it got here, and what the guest can do.
		"STATUS", "NOTE", "FAILED_STEPS", "TRANSPORT", "OS_FAMILY", "OS_VERSION", "INIT",
		"SSHD", "SSHFS", "SSHFS_VERSION", "SSHFS_MOUNT_OK", "SSHFS_MOUNTROOT",
	]

	static func read(atPath path: String) -> SSHReport? {
		guard let data = FileManager.default.contents(atPath: path),
			!data.isEmpty, data.count <= maxBytes else { return nil }
		return parse(String(decoding: data, as: UTF8.self))
	}

	static func parse(_ text: String) -> SSHReport {
		var values: [String: String] = [:]
		// components(separatedBy: .newlines), not split(separator: "\n") — Swift folds
		// CRLF into ONE Character, so a "\n" split walks straight past CRLF endings.
		for rawLine in text.components(separatedBy: .newlines) {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			guard !line.isEmpty, !line.hasPrefix("#") else { continue }
			guard let eq = line.firstIndex(of: "=") else { continue }
			let key = String(line[..<eq])
			guard allowedKeys.contains(key) else { continue }
			let value = String(line[line.index(after: eq)...])
				.trimmingCharacters(in: .whitespaces)
			guard value.count <= maxValueLength else { continue }
			values[key] = value   // last occurrence wins
		}
		return SSHReport(values: values)
	}

	// Fold the report into the persisted state. Caller saves-and-emits on true; false =
	// nothing changed (identical report re-read).
	@discardableResult
	func apply(to config: VMConfig, stampedAt: Date) throws -> Bool {
		var state = config.ssh ?? SSHConfig()
		let before = state
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
			if let user = values["USER"], !user.isEmpty { state.guestUser = user }
			if let host = values["HOSTNAME"], !host.isEmpty { state.guestHostname = host }
			if let os = values["OS_ID"], !os.isEmpty { state.guestOS = os }
			if let version = values["OS_VERSION"], !version.isEmpty {
				state.guestOSVersion = version
			}
			if let key = values["HOST_KEY"], !key.isEmpty { state.guestHostKey = key }
			// The address is a claim (the drop-box is guest-writable), kept only as the
			// fallback that survives a rename — the daemon's own discovery is the truth.
			if let ip = values["IP"], !ip.isEmpty { state.lastAddress = ip }
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
			if let reverse = values["REVERSE_PUBKEY"], !reverse.isEmpty {
				if state.reversePublicKey != reverse {
					// A new key always needs fresh approval — even if one was approved.
					state.reversePublicKey = reverse
					state.reverseState = SSHInfo.ReverseState.pending.rawValue
				} else if state.reverseStateValue == .none {
					state.reverseState = SSHInfo.ReverseState.pending.rawValue
				}
			}
		}
		guard state != before else { return false }
		state.lastReportAt = stampedAt
		config.ssh = state
		try config.saveVMConfig()
		// The guest just told us its identity: pin it where the session tabs look, so a
		// tab verifies the guest without touching the user's own ~/.ssh/known_hosts.
		SSHSetupInstaller.writeKnownHosts(for: config)
		return true
	}
}
