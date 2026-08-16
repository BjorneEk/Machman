//
//  GuestInstaller.swift
//  MachmanCore
//
//  The shared half of every generated guest-installer payload (console login, SSH setup,
//  whatever comes next): one directory under the VM carrying a read-only script, the
//  `machman.env` file that parameterizes it, and any extra files it needs. Scripts are
//  PARAMETERLESS text — everything per-VM lives in the env file the script sources — so a
//  script can be a plain .sh source, linted and run as-is, and Swift reads the version
//  line back out of it instead of declaring a second copy that can drift.
//
//  The payload dir is served to the guest read-only (VMDevices): a writable script would
//  let any guest process swap it before the admin sudo-runs it.
//

import Foundation

// A guest script Machman serves. Text-backed today; `init(bytes:)` is what the embedded
// .sh sources use.
struct EmbeddedScript {
	let text: String

	init(text: String) {
		self.text = text
	}

	init(bytes: [UInt8]) {
		self.text = String(decoding: bytes, as: UTF8.self)
	}

	// The script's own `SCRIPT_VERSION=<n>` line — the script owns its version, Swift only
	// reads it (0 when the line is missing, which no shipped script may do).
	var version: Int {
		for line in text.components(separatedBy: .newlines) {
			guard line.hasPrefix(Self.versionKey) else { continue }
			let raw = line.dropFirst(Self.versionKey.count)
				.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
			return Int(raw) ?? 0
		}
		return 0
	}

	private static let versionKey = "SCRIPT_VERSION="
}

// One generated installer payload. Implementors declare what they are; the mechanics of
// writing them live in GuestInstallerWriter, so a new installer is a name, an env, and
// (optionally) some files to ship beside the script.
protocol GuestInstallerPayload {
	// The directory name under the VM AND the name the guest sees inside the share.
	static var directoryName: String { get }
	static var scriptName: String { get }
	static var script: EmbeddedScript { get }
	// Everything per-VM the script needs, written as `machman.env` (shell-quoted).
	static func environment(for config: VMConfig) throws -> [String: String]
	// Files shipped beside the script; a nil value means "make sure this is absent".
	static func extraFiles(for config: VMConfig) throws -> [String: Data?]
}

extension GuestInstallerPayload {
	static func extraFiles(for config: VMConfig) throws -> [String: Data?] { [:] }
}

enum GuestInstallerWriter {
	// Sourced by every payload script as "$PAYLOAD_DIR/machman.env".
	static let environmentFileName = "machman.env"

	// Every generated payload lives under ONE directory in the VM, never beside its disk
	// images: guests without a virtiofs driver (FreeBSD, OpenBSD) bootstrap by
	// sshfs-mounting this directory from the Mac, and a mount that also exposed the live
	// disk images would let a running guest write its own backing store.
	static let payloadRootName = "share"

	static func payloadRoot(for config: VMConfig) -> URL {
		config.localURL(file: payloadRootName)
	}

	static func payloadDirectory(named name: String, for config: VMConfig) -> URL {
		payloadRoot(for: config).appendingPathComponent(name)
	}

	static func payloadPath(named name: String, for config: VMConfig) -> String {
		payloadDirectory(named: name, for: config).path
	}

	// Payloads written before the <vmdir>/share move sat directly under the VM directory.
	// Removing the old copy keeps exactly one served truth (the names are reserved, so
	// nothing of the user's can live there).
	static func removeLegacyPayload(named name: String, for config: VMConfig) {
		try? FileManager.default.removeItem(atPath: config.configFilePath(file: name))
	}

	// Writes (and rewrites) a payload directory. Called at every VM assembly, so it is
	// idempotent and always leaves the current content — never a merge of old and new.
	@discardableResult
	static func write<P: GuestInstallerPayload>(
		_ payload: P.Type, for config: VMConfig
	) throws -> URL {
		let fm = FileManager.default
		let dir = payloadDirectory(named: P.directoryName, for: config)
		try fm.createDirectory(at: dir, withIntermediateDirectories: true)
		removeLegacyPayload(named: P.directoryName, for: config)

		let scriptURL = dir.appendingPathComponent(P.scriptName)
		try P.script.text.write(to: scriptURL, atomically: true, encoding: .utf8)
		try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

		let envURL = dir.appendingPathComponent(environmentFileName)
		try environmentFile(try P.environment(for: config))
			.write(to: envURL, atomically: true, encoding: .utf8)
		try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: envURL.path)

		for (name, data) in try P.extraFiles(for: config) {
			let url = dir.appendingPathComponent(name)
			guard let data else {
				try? fm.removeItem(at: url)
				continue
			}
			try data.write(to: url, options: .atomic)
			try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
		}
		return dir
	}

	// `KEY='value'` lines, sorted by key: deterministic output makes the file diffable and
	// the tests exact.
	static func environmentFile(_ values: [String: String]) -> String {
		values.keys.sorted()
			.map { "\($0)=\(shellQuoted(values[$0] ?? ""))" }
			.joined(separator: "\n") + "\n"
	}

	// Single-quoted for sh: the only character needing care inside single quotes is the
	// quote itself.
	static func shellQuoted(_ value: String) -> String {
		"'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}
}
