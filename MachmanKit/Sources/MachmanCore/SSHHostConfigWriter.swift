//
//  SSHHostConfigWriter.swift
//  MachmanCore
//
//  The host side of `ssh <vm>.machman`: one marked Include line in ~/.ssh/config, a
//  wholly Machman-owned ~/.ssh/machman/config regenerated from daemon state, an
//  alias-keyed known_hosts (HostKeyAlias — pinning survives DHCP renumbering), and the
//  labeled reverse-access lines in ~/.ssh/authorized_keys. The base directory is
//  injected so tests never touch the real ~/.ssh; the daemon owns the one live instance.
//  Never edits the user's own content: the Include line and authorized_keys lines are
//  exact-match surgical, the managed file is ours outright.
//

import Foundation
import MachmanAPI

public struct SSHHostConfigWriter {
	let sshDir: URL

	// Relative Include paths resolve against ~/.ssh for user configs, so the line works
	// regardless of where the home directory lives. The trailing comment is the marker
	// add/remove key off — never reformat it.
	public static let includeLine = "Include machman/config # machman managed"

	public init(sshDir: URL = FileManager.default.homeDirectoryForCurrentUser
		.appendingPathComponent(".ssh")) {
		self.sshDir = sshDir
	}

	public struct VMEntry {
		public var name: String
		// The Host name this VM answers to. Passed in, never derived here: naming policy
		// belongs to the config (a VM can override it), not to the file writer.
		public var alias: String
		public var user: String?
		public var address: String?          // nil = keep whatever the managed file last knew
		public var identityFilePath: String?
		public var hostKey: String?          // guest host public key line; nil → accept-new

		public init(
			name: String, alias: String, user: String?, address: String?,
			identityFilePath: String?, hostKey: String?
		) {
			self.name = name
			self.alias = alias
			self.user = user
			self.address = address
			self.identityFilePath = identityFilePath
			self.hostKey = hostKey
		}
	}

	private var managedDir: URL { sshDir.appendingPathComponent("machman") }
	private var managedConfig: URL { managedDir.appendingPathComponent("config") }
	private var knownHosts: URL { managedDir.appendingPathComponent("known_hosts") }
	private var userConfig: URL { sshDir.appendingPathComponent("config") }
	private var authorizedKeys: URL { sshDir.appendingPathComponent("authorized_keys") }

	// The alias a VM gets unless its config names another one (SSHConfig.alias), mapped
	// into the alias charset: "dev copy" → dev-copy.machman (decision 4). A raw spaced name
	// here made OpenSSH refuse the whole file — and with it every ssh on the Mac.
	public static func defaultAlias(for vmName: String) -> String {
		SSHAliasRule.defaultAlias(for: vmName)
	}

	// MARK: - Whole-state regeneration

	// Rewrites the managed config + known_hosts from the given entries and keeps the
	// Include line present exactly while there is something to include.
	public func apply(entries: [VMEntry]) throws {
		let fm = FileManager.default
		let previous = previousHostNames()
		// A block with no HostName would make `ssh <alias>` fail with a DNS-flavored
		// error — an alias only exists once SOME address is known (fresh discovery, or
		// the file's own last-known value: the file is the persistence across restarts).
		var claimed = Set<String>()
		let addressed = entries.compactMap { served -> (VMEntry, String)? in
			var entry = served
			// One malformed Host line stops OpenSSH for every host, and an older vmhost may
			// still serve the raw "<name>.machman" — map it like the default is mapped.
			if !SSHAliasRule.isWellFormed(entry.alias) {
				entry.alias = SSHAliasRule.defaultAlias(for: entry.name)
			}
			// Guest-reported values are claims (S22): only an IP literal is ever a HostName,
			// whether it comes from discovery, the report or the previous file.
			guard let address = [entry.address, previous[entry.alias]]
				.compactMap({ $0 }).first(where: GuestValueRule.isAddress)
				else { return nil }
			// Backstop only: aliases are made unique where a VM takes one. Two blocks with
			// one Host name would silently merge settings across VMs, so the first wins.
			// Exact compare — OpenSSH matches Host patterns case-sensitively.
			guard claimed.insert(entry.alias).inserted else {
				MachmanLogger.log(.log,
					"\(entry.name): \(entry.alias) already names another VM in ~/.ssh — skipped")
				return nil
			}
			return (entry, address)
		}
		guard !addressed.isEmpty else {
			try setIncludeLine(present: false)
			try? fm.removeItem(at: managedConfig)
			try? fm.removeItem(at: knownHosts)
			// The managed dir holds only those two files; when the last SSH VM goes,
			// nothing of Machman's should outlive it in ~/.ssh.
			removeEmptyDirectory(managedDir.path)
			return
		}
		try fm.createDirectory(at: managedDir, withIntermediateDirectories: true)
		try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: managedDir.path)
		var config = [
			"# Managed by Machman — do not edit; regenerated from the app's SSH state.",
			"# One Host block per VM with SSH integration enabled (ssh \"<vm>.machman\").",
			"",
		]
		var pins: [String] = []
		for (entry, address) in addressed {
			let alias = entry.alias
			config.append("Host \"\(alias)\"")
			config.append("\tHostName \(address)")
			// A user outside the guest's own user-name charset is left out: ssh then uses
			// the Mac account, which fails safe ("User a b" stops every ssh; "User $(…)"
			// reaches a shell through a %r ProxyCommand).
			if let user = entry.user, GuestValueRule.isUserName(user) {
				config.append("\tUser \(user)")
			}
			if let identity = entry.identityFilePath {
				config.append("\tIdentityFile \"\(identity)\"")
				config.append("\tIdentitiesOnly yes")
			}
			// Alias-keyed pinning: the recorded host key stays valid however often the
			// NAT lease moves. No key reported yet (NixOS partial reports) → accept-new
			// rather than bricking the alias.
			config.append("\tHostKeyAlias \(alias)")
			config.append("\tUserKnownHostsFile \"\(knownHosts.path)\"")
			if let hostKey = entry.hostKey, GuestValueRule.isPublicKeyLine(hostKey) {
				config.append("\tStrictHostKeyChecking yes")
				let fields = hostKey.split(separator: " ")
				pins.append("\(alias) \(fields[0]) \(fields[1])")
			} else {
				config.append("\tStrictHostKeyChecking accept-new")
			}
			config.append("")
		}
		try write(config.joined(separator: "\n") + "\n", to: managedConfig)
		try write(pins.joined(separator: "\n") + (pins.isEmpty ? "" : "\n"), to: knownHosts)
		try setIncludeLine(present: true)
	}

	// HostName values from the current managed file, keyed by alias — the fallback that
	// makes whole-file regeneration keep last-known addresses.
	private func previousHostNames() -> [String: String] {
		guard let text = try? String(contentsOf: managedConfig, encoding: .utf8) else {
			return [:]
		}
		var result: [String: String] = [:]
		var currentAlias: String?
		for rawLine in text.components(separatedBy: .newlines) {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			if line.hasPrefix("Host ") {
				currentAlias = line.dropFirst("Host ".count)
					.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
			} else if line.hasPrefix("HostName "), let alias = currentAlias {
				result[alias] = String(line.dropFirst("HostName ".count))
			}
		}
		return result
	}

	// MARK: - The Include line in the user's config

	private func setIncludeLine(present: Bool) throws {
		let fm = FileManager.default
		let existing = (try? String(contentsOf: userConfig, encoding: .utf8)) ?? ""
		var lines = existing.isEmpty ? [] : existing.components(separatedBy: "\n")
		let had = lines.contains(Self.includeLine)
		if present, !had {
			// At the top: Include must sit outside any Host block to apply globally.
			try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)
			try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)
			lines.insert(Self.includeLine, at: 0)
		} else if !present, had {
			lines.removeAll { $0 == Self.includeLine }
			if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
				// The file was ours alone — but deleting the user's config file is not
				// our call; leave an empty file rather than removing it.
				lines = []
			}
		} else {
			return
		}
		try write(lines.joined(separator: "\n"), to: userConfig)
	}

	// MARK: - Reverse access (authorized_keys)

	// Installs (or removes, keyLine nil) the labeled reverse-key line. Exact-match
	// surgery: only lines carrying "machman:<marker>" are ever touched.
	public func setReverseKey(_ keyLine: String?, marker: String, vmName: String) throws {
		let fm = FileManager.default
		let label = "machman:\(marker)"
		let existing = (try? String(contentsOf: authorizedKeys, encoding: .utf8)) ?? ""
		var lines = existing.components(separatedBy: "\n")
			.filter { !$0.contains(label) }
		while lines.last?.isEmpty == true { lines.removeLast() }
		if let keyLine {
			let trimmed = keyLine.trimmingCharacters(in: .whitespacesAndNewlines)
			// A guest-reported line: options (command="…", from=…) or a second line would
			// grant the guest more than this one key.
			guard GuestValueRule.isPublicKeyLine(trimmed) else {
				throw MachmanError(
					code: .invalidArgument,
					message: "The guest's reverse key isn't a public-key line")
			}
			lines.append("\(trimmed) \(label):\(vmName)")
		} else if existing.isEmpty {
			return   // nothing to remove, don't create the file
		}
		try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)
		try write(lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"), to: authorizedKeys)
	}

	private func write(_ content: String, to url: URL) throws {
		try content.write(to: url, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o600], ofItemAtPath: url.path)
	}
}
