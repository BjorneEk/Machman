//
//  GuestSetupStore.swift
//  MachmanCore
//
//  Every Guest Setup script Machman serves or is given, kept on the host (S67):
//  <data dir>/GuestSetup/scripts/<id>/ holds the script and an entry.json describing it. A VM
//  pins one entry (setup.script) and its vmhost serves those bytes, so an app update never
//  changes what an existing VM serves. Ids name the content: v<N>-<digest> for a build's own
//  script, custom-<digest> for one the user imported, changed-<digest> for a copy a guest
//  changed and ran. The store sits outside every VM, so no guest reaches it, and Machman never
//  deletes an entry. The daemon and the vmhosts share it: an entry is written whole into a
//  staging directory and renamed into place, so a reader finds all of it or none of it.
//

import Foundation
import CryptoKit
import MachmanAPI

// <data dir>/GuestSetup/scripts, beside the VM library. A vmhost sets it from its library at
// launch: a safe run's scan root is its run root, not the library.
var machmanSetupScriptsDir: String = GuestSetupStore.directory(forLibrary: machmanVMDir)

struct GuestSetupStore {
	// What an entry is (Entry.kind): the wire's plain strings.
	typealias Kind = GuestSetupScriptKind

	struct Entry: Codable, Equatable, Sendable {
		var id: String
		var kind: String
		var version: Int?         // the script's SCRIPT_VERSION line; nil without one
		var cksum: String         // its POSIX cksum, "<crc> <length>" — what a report names
		var sha256: String        // hex; the id's digest is its first 12 characters
		var addedAt: Date?        // nil only for this build's script before it is stored
		var vm: String?           // the VM it was imported for or captured from
		var label: String?        // an imported script's file name

		// The script's size in bytes: the cksum's second field.
		var byteCount: Int? {
			cksum.split(separator: " ").last.flatMap { Int($0) }
		}
	}

	// A script with its entry, as a build serves it before (or without) the disk.
	struct Script: Sendable {
		let data: Data
		let entry: Entry

		init(data: Data, kind: String = Kind.build, addedAt: Date? = nil) {
			self.init(
				data: data, entry: GuestSetupStore.describe(data, kind: kind, addedAt: addedAt))
		}

		init(data: Data, entry: Entry) {
			self.data = data
			self.entry = entry
		}
	}

	static let scriptName = "install.sh"
	static let entryName = "entry.json"
	// An imported or captured script is a text file the size of the build's (about 220 KB).
	static let maxScriptBytes = 1 << 20

	let root: URL
	let builtIn: Script

	init(root: URL, builtIn: Script = GuestSetupStore.thisBuild) {
		self.root = root
		self.builtIn = builtIn
	}

	// The store every engine path uses: the global directory and this build's script.
	static var current: GuestSetupStore {
		GuestSetupStore(root: URL(fileURLWithPath: machmanSetupScriptsDir, isDirectory: true))
	}

	// Assembled, hashed and summed once per process.
	static let thisBuild = Script(data: Data(GuestSetupInstaller.script.text.utf8))

	static func directory(forLibrary library: String) -> String {
		(library as NSString).deletingLastPathComponent + "/GuestSetup/scripts"
	}

	static func describe(_ data: Data, kind: String, addedAt: Date?) -> Entry {
		let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
		let version = EmbeddedScript(bytes: Array(data)).version
		let prefix = kind == Kind.build ? "v\(version)" : kind
		return Entry(
			id: prefix + "-" + sha.prefix(12), kind: kind, version: version == 0 ? nil : version,
			cksum: POSIXChecksum.cksum(data), sha256: sha, addedAt: addedAt)
	}

	// MARK: - Reading

	// The stored entries plus this build's, whether or not it is on disk yet.
	func entries() -> [Entry] {
		var all = stored()
		if !all.contains(where: { $0.id == builtIn.entry.id }) {
			all.append(builtIn.entry)
		}
		return all
	}

	func entry(id: String) -> Entry? {
		entries().first { $0.id == id }
	}

	// The newest build's script: the highest version, this build's on a tie, else the one
	// stored last. Never an imported or captured one, whatever version it says.
	var latest: Entry {
		let builds = entries().filter { $0.kind == Kind.build }
		return builds.max { a, b in
			if (a.version ?? 0) != (b.version ?? 0) { return (a.version ?? 0) < (b.version ?? 0) }
			if a.id == builtIn.entry.id || b.id == builtIn.entry.id {
				return b.id == builtIn.entry.id
			}
			return (a.addedAt ?? .distantPast) < (b.addedAt ?? .distantPast)
		} ?? builtIn.entry
	}

	// The entries whose script has this cksum, newest first.
	func matching(cksum: String) -> [Entry] {
		entries().filter { $0.cksum == cksum }
			.sorted { ($0.addedAt ?? .distantFuture) > ($1.addedAt ?? .distantFuture) }
	}

	// An entry's script, checked against its digest; nil when it is gone or no longer whole.
	func script(id: String) -> Data? {
		if id == builtIn.entry.id { return builtIn.data }
		guard let entry = stored().first(where: { $0.id == id }),
			let data = Self.readScript(at: scriptURL(id))
		else { return nil }
		return Self.digest(data) == entry.sha256 ? data : nil
	}

	private func scriptURL(_ id: String) -> URL {
		root.appendingPathComponent(id).appendingPathComponent(Self.scriptName)
	}

	private static func digest(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}

	private static func readScript(at url: URL) -> Data? {
		var info = stat()
		guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
			info.st_size <= maxScriptBytes else { return nil }
		return try? Data(contentsOf: url)
	}

	// MARK: - On the wire

	// Every entry as GuestSetupInfo.scripts lists it, the latest marked.
	func wireInfos() -> [GuestSetupScriptInfo] {
		let latest = latest.id
		return entries().map { wireInfo($0, latest: latest) }
	}

	func wireInfo(_ entry: Entry, latest: String? = nil) -> GuestSetupScriptInfo {
		GuestSetupScriptInfo(
			id: entry.id, kind: entry.kind, version: entry.version, label: entry.label,
			vm: entry.vm, addedAt: entry.addedAt,
			latest: entry.id == (latest ?? self.latest.id) ? true : nil)
	}

	// The entry a report's script cksum names — the served one when several share it.
	func installedID(cksum: String?, served: String) -> String? {
		guard let cksum else { return nil }
		let found = matching(cksum: cksum)
		return found.first { $0.id == served }?.id ?? found.first?.id
	}

	// MARK: - The cache

	private static let lock = NSLock()
	private static var cache: [String: (stamp: [Int], entries: [Entry])] = [:]
	private static var reported: Set<String> = []

	// Adding an entry renames a directory into the root, which moves the root's mtime: the
	// listing is read again only then.
	private func stored() -> [Entry] {
		var info = stat()
		guard stat(root.path, &info) == 0 else { return [] }
		let stamp = [
			Int(info.st_ino), Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec),
		]
		Self.lock.lock()
		if let hit = Self.cache[root.path], hit.stamp == stamp {
			Self.lock.unlock()
			return hit.entries
		}
		Self.lock.unlock()
		let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
		let entries = names.sorted().filter { !$0.hasPrefix(".") }.compactMap(readEntry)
		Self.lock.lock()
		Self.cache[root.path] = (stamp, entries)
		Self.lock.unlock()
		return entries
	}

	// One entry as stored, or nil — said once — when its description or script is missing,
	// or the script isn't the file and size it was stored as. A listing reads no script: the
	// digest is checked where the bytes are used, at serve and pin (script(id:)).
	private func readEntry(_ name: String) -> Entry? {
		let dir = root.appendingPathComponent(name)
		var info = stat()
		guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.entryName)),
			let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.id == name,
			lstat(dir.appendingPathComponent(Self.scriptName).path, &info) == 0,
			(info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) == entry.byteCount
		else {
			Self.lock.lock()
			let first = Self.reported.insert(dir.path).inserted
			Self.lock.unlock()
			if first {
				MachmanLogger.log(.log, "Guest Setup store: left out \(name) — it isn’t whole")
			}
			return nil
		}
		return entry
	}

	private static func invalidate(_ root: URL) {
		lock.lock()
		cache[root.path] = nil
		lock.unlock()
	}

	// MARK: - Writing

	// host.setupScripts.import: a script file kept as a custom one, labeled with its name and
	// dated with the VM it is for.
	func importScript(atPath path: String, vm: String?) throws -> Entry {
		try add(
			Self.readImport(atPath: path), kind: Kind.custom, vm: vm,
			label: (path as NSString).lastPathComponent)
	}

	// A script file the user picked: a regular file of UTF-8 text within the size cap,
	// refused in words that name it.
	static func readImport(atPath path: String) throws -> Data {
		let name = (path as NSString).lastPathComponent
		var info = stat()
		guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
			throw MachmanError(code: .invalidArgument, message: "“\(name)” isn’t a file")
		}
		guard info.st_size <= maxScriptBytes else {
			throw MachmanError(code: .invalidArgument, message: "“\(name)” is larger than 1 MB")
		}
		let data: Data
		do {
			data = try Data(contentsOf: URL(fileURLWithPath: path))
		} catch {
			throw MachmanError(
				code: .ioFailure,
				message: "Couldn’t read “\(name)”: \(MachmanError.userMessage(for: error))")
		}
		guard isText(data) else {
			throw MachmanError(code: .invalidArgument, message: "“\(name)” isn’t a text file")
		}
		return data
	}

	// What the store takes as a script, imported or captured: UTF-8 text within the size cap,
	// with no NUL byte.
	static func isText(_ data: Data) -> Bool {
		!data.isEmpty && data.count <= maxScriptBytes && !data.contains(0)
			&& String(data: data, encoding: .utf8) != nil
	}

	// Keeps a script, once per content: a script already stored (or this build's) answers
	// with its entry as it stands, its first date and VM kept.
	@discardableResult
	func add(
		_ data: Data, kind: String, vm: String? = nil, label: String? = nil, at date: Date = Date()
	) throws -> Entry {
		guard data.count <= Self.maxScriptBytes else {
			throw MachmanError(
				code: .invalidArgument, message: "A Guest Setup script is at most 1 MB")
		}
		let sha = Self.digest(data)
		if let known = stored().first(where: { $0.sha256 == sha }) { return known }
		var entry = Self.describe(data, kind: kind, addedAt: date)
		if sha == builtIn.entry.sha256 { entry = builtIn.entry; entry.addedAt = date }
		entry.vm = entry.kind == Kind.build ? nil : vm
		entry.label = entry.kind == Kind.custom ? label : nil
		try write(entry, script: data)
		return stored().first { $0.id == entry.id } ?? entry
	}

	// This build's script on disk, so a later build still serves it to the VMs pinned to it.
	// Failures are logged: this build serves its own script from memory either way.
	@discardableResult
	func ensureBuiltIn() -> Entry? {
		if let stored = stored().first(where: { $0.id == builtIn.entry.id }) { return stored }
		do {
			return try add(builtIn.data, kind: Kind.build)
		} catch {
			MachmanLogger.log(.passiveWarning,
				"couldn’t keep this build’s Guest Setup script in \(root.path): "
					+ MachmanError.userMessage(for: error))
			return nil
		}
	}

	private func write(_ entry: Entry, script: Data) throws {
		let fm = FileManager.default
		try fm.createDirectory(
			at: root, withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700])
		let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)")
		defer { try? fm.removeItem(at: staging) }
		try fm.createDirectory(at: staging, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		for (name, data) in [
			(Self.scriptName, script), (Self.entryName, try encoder.encode(entry)),
		] {
			let url = staging.appendingPathComponent(name)
			try data.write(to: url)
			try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
		}
		let final = root.appendingPathComponent(entry.id)
		// Another process may have stored the same script a moment ago: theirs stands.
		if renamex_np(staging.path, final.path, UInt32(RENAME_EXCL)) != 0, errno != EEXIST,
			errno != ENOTEMPTY {
			let reason = String(cString: strerror(errno))
			throw MachmanError(
				code: .ioFailure, message: "Couldn’t keep the Guest Setup script: \(reason)")
		}
		Self.invalidate(root)
	}
}
