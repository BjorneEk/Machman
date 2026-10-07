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
//  exact-match surgical, the managed file is ours outright. The user's files keep their
//  mode, and a linked one (stow, home-manager, chezmoi) is written through, never replaced.
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
			// A VM directory path the file can't carry (a line break in a legacy VM name)
			// would end the line early and inject the rest as config.
			if let identity = entry.identityFilePath,
				SSHConfigQuote.argument(identity, expandsTokens: true) == nil {
				MachmanLogger.log(.log,
					"\(entry.name): its key path can't be written into ~/.ssh — skipped")
				return nil
			}
			// Guest-reported values are claims (S22): only an IP literal is ever a HostName,
			// whether it comes from discovery, the report or the previous file.
			guard let address = [entry.address, previous[entry.alias]]
				.compactMap({ $0 }).first(where: GuestValueRule.isAddress)
				else { return nil }
			// Backstop only: aliases are made unique where a VM takes one. Two blocks with
			// one Host name would silently merge settings across VMs, so the first wins.
			// Case folded (C31): Host patterns match case-sensitively, but HostKeyAlias is
			// lowercased and known_hosts read case-insensitively, so two aliases differing
			// only in case would share one pin.
			guard claimed.insert(entry.alias.lowercased()).inserted else {
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
		guard let knownHostsValue = SSHConfigQuote.argument(knownHosts.path, expandsTokens: true)
		else {
			throw MachmanError(
				code: .ioFailure, message: "The ~/.ssh path can’t be written into an ssh config")
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
			if let identity = entry.identityFilePath.flatMap({
				SSHConfigQuote.argument($0, expandsTokens: true)
			}) {
				config.append("\tIdentityFile \(identity)")
				config.append("\tIdentitiesOnly yes")
			}
			// Alias-keyed pinning: the recorded host key stays valid however often the
			// NAT lease moves. No key reported yet (NixOS partial reports) → accept-new
			// rather than bricking the alias.
			config.append("\tHostKeyAlias \(alias)")
			config.append("\tUserKnownHostsFile \(knownHostsValue)")
			if let hostKey = entry.hostKey, GuestValueRule.isPublicKeyLine(hostKey) {
				config.append("\tStrictHostKeyChecking yes")
				let fields = hostKey.split(separator: " ")
				pins.append("\(alias) \(fields[0]) \(fields[1])")
			} else {
				config.append("\tStrictHostKeyChecking accept-new")
			}
			config.append("")
		}
		try write(
			Data((config.joined(separator: "\n") + "\n").utf8), to: managedConfig,
			userFile: false)
		try write(
			Data((pins.joined(separator: "\n") + (pins.isEmpty ? "" : "\n")).utf8),
			to: knownHosts, userFile: false)
		try setIncludeLine(present: true)
	}

	// HostName values from the current managed file, keyed by alias — the fallback that
	// makes whole-file regeneration keep last-known addresses. Decoded lossily: a stray byte
	// someone typed into it must not forget every address.
	private func previousHostNames() -> [String: String] {
		guard let data = FileManager.default.contents(atPath: managedConfig.path) else {
			return [:]
		}
		let text = String(decoding: data, as: UTF8.self)
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
		var lines = Self.lines(of: try readUserFile(userConfig))
		let include = Data(Self.includeLine.utf8)
		let had = lines.contains(include)
		if present, !had {
			// At the top: Include must sit outside any Host block to apply globally.
			try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)
			try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)
			lines.insert(include, at: 0)
		} else if !present, had {
			lines.removeAll { $0 == include }
			if lines.allSatisfy({ $0.allSatisfy { $0 == 0x20 || $0 == 0x09 } }) {
				// The file was ours alone — but deleting the user's config file is not
				// our call; leave an empty file rather than removing it.
				lines = []
			}
		} else {
			return
		}
		try write(Self.joined(lines), to: userConfig, userFile: true)
	}

	// MARK: - Reverse access (authorized_keys)

	// Whether authorized_keys holds this VM's labeled line; throws when it can't be read.
	public func hasReverseKey(marker: String) throws -> Bool {
		let label = Data("machman:\(marker)".utf8)
		return Self.lines(of: try readUserFile(authorizedKeys))
			.contains { $0.range(of: label) != nil }
	}

	// Installs (or removes, keyLine nil) the labeled reverse-key line. Exact-match
	// surgery: only lines carrying "machman:<marker>" are ever touched, and a removal that
	// finds none leaves the file as it is.
	public func setReverseKey(_ keyLine: String?, marker: String, vmName: String) throws {
		let fm = FileManager.default
		let label = "machman:\(marker)"
		let all = Self.lines(of: try readUserFile(authorizedKeys))
		var lines = all.filter { $0.range(of: Data(label.utf8)) == nil }
		if keyLine == nil, lines.count == all.count { return }
		while lines.last?.isEmpty == true { lines.removeLast() }
		if let keyLine {
			let trimmed = keyLine.trimmingCharacters(in: .whitespacesAndNewlines)
			// A guest-reported line: options (command="…", from=…) or a second line would
			// grant the guest more than this one key.
			guard GuestValueRule.isPublicKeyLine(trimmed) else {
				throw MachmanError(
					code: .invalidArgument,
					message: "The guest’s reverse key isn’t a public-key line")
			}
			// The label rides the key's comment: a legacy VM name with a line break must not
			// split it into a second line.
			let labelName = vmName.unicodeScalars.map {
				NameRule.hasControlCharacters(String($0)) ? "-" : String($0)
			}.joined()
			lines.append(Data("\(trimmed) \(label):\(labelName)".utf8))
		}
		try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)
		var content = Self.joined(lines)
		if !lines.isEmpty { content.append(0x0A) }
		try write(content, to: authorizedKeys, userFile: true)
	}

	// MARK: - The user's files, as bytes

	// The user's file as it is on disk: empty when there is none, an error when it exists but
	// can't be read. Never "empty" for that — the write that follows would replace the file
	// with Machman's line alone (C20).
	private func readUserFile(_ url: URL) throws -> Data {
		do {
			return try Data(contentsOf: url)
		} catch CocoaError.fileReadNoSuchFile {
			return Data()
		} catch {
			throw MachmanError(
				code: .ioFailure,
				message: "Couldn’t read \(url.path): \(MachmanError.userMessage(for: error))")
		}
	}

	// Lines are split and joined on the newline byte and compared as bytes, so a user's line
	// in any encoding (a Latin-1 "café" comment) goes back exactly as it came.
	private static func lines(of data: Data) -> [Data] {
		data.isEmpty ? [] : data.split(separator: 0x0A, omittingEmptySubsequences: false)
	}

	private static func joined(_ lines: [Data]) -> Data {
		Data(lines.joined(separator: [0x0A]))
	}

	// Machman's own files are 0600. The user's own files (~/.ssh/config, authorized_keys)
	// keep their mode, and when one is a symbolic link the write goes to the file it points
	// at: an atomic write to the link's path would replace the link with a plain file and
	// silently detach the user's managed copy (S23). A link to a missing or unwritable file
	// (a broken stow link, the read-only nix store) is refused, never replaced.
	private func write(_ content: Data, to url: URL, userFile: Bool) throws {
		let fm = FileManager.default
		let target = userFile ? try writeTarget(for: url) : url
		let priorMode = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions]
			as? NSNumber
		do {
			try content.write(to: target, options: .atomic)
		} catch where target != url {
			throw MachmanError(
				code: .ioFailure,
				message: "\(url.path) links to \(target.path), which can’t be written")
		} catch {
			throw MachmanError(
				code: .ioFailure,
				message: "Couldn’t write \(url.path): \(MachmanError.userMessage(for: error))")
		}
		let mode = userFile ? priorMode?.intValue ?? 0o600 : 0o600
		try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
	}

	// The file a write to `url` must go to: `url` itself, or the end of its link chain.
	private func writeTarget(for url: URL) throws -> URL {
		let fm = FileManager.default
		var current = url
		for _ in 0..<16 {
			guard let destination = try? fm.destinationOfSymbolicLink(atPath: current.path)
			else {
				if current != url, !fm.fileExists(atPath: current.path) {
					throw MachmanError(
						code: .ioFailure,
						message: "\(url.path) links to a file that doesn’t exist")
				}
				return current
			}
			current = destination.hasPrefix("/")
				? URL(fileURLWithPath: destination)
				: current.deletingLastPathComponent().appendingPathComponent(destination)
					.standardizedFileURL
		}
		throw MachmanError(code: .ioFailure, message: "\(url.path) links through too many links")
	}
}
