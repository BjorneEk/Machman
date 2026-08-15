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
	static let allowedKeys: Set<String> = [
		"SCRIPT_VERSION", "MARKER", "OS_ID", "USER", "HOME", "HOSTNAME",
		"IP", "GATEWAY", "TWO_WAY", "HOST_KEY", "REVERSE_PUBKEY", "UNINSTALLED",
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
			// user's switches and the marker stay.
			state.guestUser = nil
			state.guestHostname = nil
			state.guestOS = nil
			state.guestHostKey = nil
			state.reversePublicKey = nil
			state.reverseState = SSHInfo.ReverseState.none.rawValue
		} else {
			if let user = values["USER"], !user.isEmpty { state.guestUser = user }
			if let host = values["HOSTNAME"], !host.isEmpty { state.guestHostname = host }
			if let os = values["OS_ID"], !os.isEmpty { state.guestOS = os }
			if let key = values["HOST_KEY"], !key.isEmpty { state.guestHostKey = key }
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
		return true
	}
}
