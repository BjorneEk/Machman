//
//  THGuestFiles.swift
//  MachmanLabTests
//
//  What a Guest Setup row reads back: a guest file's owner, group and mode; a fingerprint of
//  whole trees (did a "changes nothing" run change nothing?); Machman's marked blocks in a
//  file; the payload's marker and the report as the host sees them.
//

import Foundation
import MachmanAPI
import Testing

enum THGuestFiles {
	struct Stat: Equatable, CustomStringConvertible {
		var owner: String
		var group: String
		var mode: String
		var description: String { "\(owner):\(group) \(mode)" }
	}

	/// `path`'s owner, group and permission bits (octal, e.g. "600").
	static func stat(_ g: any THGuest, _ path: String) async throws -> Stat {
		let format = g.kind.isLinux ? "stat -c '%U %G %a'" : "stat -f '%Su %Sg %Lp'"
		let out = try await g.check("\(format) \(ShellQuote.single(path))")
		let words = out.split(separator: " ").map(String.init)
		guard words.count == 3 else {
			throw LabError.commandFailed(command: "stat \(path)", status: 0, output: out)
		}
		return Stat(owner: words[0], group: words[1], mode: words[2])
	}

	/// The default trees a "changes nothing" row fingerprints, and what changes on its own.
	static let trees = [
		"/etc", "/root", "/home", "/usr/home", "/usr/local/etc", "/var/lib/machman",
		"/var/db/machman",
	]
	static let volatile = [
		"/etc/resolv.conf", "/etc/adjtime", "/etc/ld.so.cache", "_history", ".lesshst",
		".viminfo", "/etc/.pwd.lock", "/root/.ssh/known_hosts",
	]

	/// A digest of every regular file under `paths` (content, owner, mode) but those whose path
	/// contains an `excluding` item. The listing stays in the guest under /var/tmp for diff.
	static func fingerprint(
		_ g: any THGuest, paths: [String] = trees, excluding: [String] = volatile
	) async throws -> Fingerprint {
		let n = THCounter.next()
		let list = "/var/tmp/th-fp-\(n)"
		let filter = excluding.map { "-e \(ShellQuote.single($0))" }.joined(separator: " ")
		let stat = g.kind.isLinux ? "stat -c '%a %u %g %n'" : "stat -f '%Lp %u %g %N'"
		let existing = paths.map(ShellQuote.single).joined(separator: " ")
		let command = "for p in \(existing); do [ -e \"$p\" ] && find \"$p\" -xdev -type f; done"
			+ " | grep -v -F \(filter) | LC_ALL=C sort | while IFS= read -r f; do"
			+ " printf '%s %s\\n' \"$(\(stat) \"$f\")\" \"$(cksum < \"$f\")\"; done > \(list)"
			+ " && cksum < \(list)"
		let digest = try await g.check(command, timeout: .seconds(300))
		return Fingerprint(path: list, digest: digest)
	}

	struct Fingerprint {
		let path: String
		let digest: String
	}

	/// The files whose content, owner or mode differ between two fingerprints (or that only
	/// one of them has), but those whose path contains an `ignoring` item; "" when none.
	static func changes(
		_ g: any THGuest, from a: Fingerprint, to b: Fingerprint, ignoring: [String]
	) async throws -> String {
		let filter = ignoring.isEmpty ? "cat"
			: "grep -v -F " + ignoring.map { "-e \(ShellQuote.single($0))" }
				.joined(separator: " ")
		let out = try await g.sh(
			"\(filter) < \(a.path) > \(a.path).f; \(filter) < \(b.path) > \(b.path).f;"
				+ " diff \(a.path).f \(b.path).f | grep '^[<>]' | head -n 60; true")
		return out.output.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// The lines that differ between two fingerprints (for a failure message).
	static func diff(_ g: any THGuest, _ a: Fingerprint, _ b: Fingerprint) async -> String {
		(try? await g.sh("diff \(a.path) \(b.path) | head -n 40").output) ?? "?"
	}

	/// How many of Machman's blocks for `marker` `file` holds ("# BEGIN <marker>…" lines).
	static func markerBlocks(_ g: any THGuest, _ file: String, marker: String) async throws
		-> Int {
		let out = try await g.sh(
			"grep -c -F \(ShellQuote.single("BEGIN \(marker)")) \(ShellQuote.single(file))")
		return Int(out.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
	}

	/// The payload's machman.env as the host wrote it (values unquoted).
	static func payloadEnv(_ vm: THVM) throws -> [String: String] {
		try envFile(vm.payloadDir + "/machman.env")
	}

	/// This VM's marker (machman-<12 hex>).
	static func marker(_ vm: THVM) throws -> String {
		guard let marker = try payloadEnv(vm)["MARKER"], !marker.isEmpty else {
			throw LabError.specInvalid("\(vm.name)'s payload has no MARKER")
		}
		return marker
	}

	/// The guest's report.env as the host sees it in the share.
	static func reportEnv(_ vm: THVM) throws -> [String: String] {
		try envFile(vm.reportFile)
	}

	static func envFile(_ path: String) throws -> [String: String] {
		let text = try String(contentsOfFile: path, encoding: .utf8)
		var values: [String: String] = [:]
		for line in text.split(separator: "\n") where !line.hasPrefix("#") {
			guard let equals = line.firstIndex(of: "=") else { continue }
			var value = String(line[line.index(after: equals)...])
			if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
				value = String(value.dropFirst().dropLast())
					.replacingOccurrences(of: #"'\''"#, with: "'")
			} else if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
				value = String(value.dropFirst().dropLast())
			}
			values[String(line[..<equals])] = value
		}
		return values
	}
}
