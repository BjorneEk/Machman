//
//  Snapshot.swift
//  hostwatch
//
//  The before/after snapshot of the paths a lab run must not touch, and their diff.
//  Hash for small regular files, size + mtime for big ones; ~/.ssh by metadata only; nothing
//  under ~/.machman is ever read. Walks use lstat and never follow links.
//

import CryptoKit
import Foundation

struct SnapshotRoot {
	var path: String
	var metaOnly: Bool
	/// When set: only the direct children whose name starts with this (preference plists).
	var namePrefix: String?
}

private func realHome() -> String {
	guard let entry = getpwuid(getuid()) else { return NSHomeDirectory() }
	return String(cString: entry.pointee.pw_dir)
}

private func userTempDir() -> String {
	var buffer = [CChar](repeating: 0, count: 1024)
	let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
	return n > 0 ? String(cString: buffer) : NSTemporaryDirectory()
}

private func isUnderDotMachman(_ path: String, home: String) -> Bool {
	let root = (home as NSString).appendingPathComponent(".machman")
	let standard = (path as NSString).standardizingPath
	return standard == root || standard.hasPrefix(root + "/")
}

private func defaultRoots(home: String, token: String?) -> [SnapshotRoot] {
	let support = home + "/Library/Application Support/"
	let temp = userTempDir()
	var roots = [
		SnapshotRoot(path: support + "com.gustaffranzen.Machman.dev", metaOnly: false),
		SnapshotRoot(path: support + "com.gustaffranzen.Machman", metaOnly: false),
		SnapshotRoot(path: home + "/Library/LaunchAgents", metaOnly: false),
		SnapshotRoot(
			path: home + "/Library/Preferences", metaOnly: false,
			namePrefix: "com.gustaffranzen.Machman"),
		SnapshotRoot(path: home + "/.ssh", metaOnly: true),
		SnapshotRoot(path: temp + "com.gustaffranzen.Machman.dev", metaOnly: true),
		SnapshotRoot(path: temp + "com.gustaffranzen.Machman", metaOnly: true),
	]
	for domain in ["com.gustaffranzen.Machman.dev", "com.gustaffranzen.Machman"] {
		let raw = CFPreferencesCopyAppValue("MachmanDataDir" as CFString, domain as CFString)
		if let dir = raw as? String, dir.hasPrefix("/"), !isUnderDotMachman(dir, home: home) {
			roots.append(SnapshotRoot(path: dir, metaOnly: false))
		}
	}
	if let token {
		roots.append(SnapshotRoot(path: support + "com.gustaffranzen.Machman.test-" + token,
			metaOnly: false))
	}
	return roots
}

private func entry(at path: String, metaOnly: Bool) -> [String: Any] {
	var info = stat()
	guard lstat(path, &info) == 0 else { return ["error": String(cString: strerror(errno))] }
	let mode = Int(info.st_mode)
	var result: [String: Any] = [
		"mode": mode & 0o7777,
		"size": Int(info.st_size),
		"inode": String(info.st_ino),
		"mtimeNs": Int(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int(info.st_mtimespec.tv_nsec),
	]
	switch info.st_mode & S_IFMT {
	case S_IFREG:
		result["type"] = "file"
		if !metaOnly, info.st_size < 1 << 20,
			let data = FileManager.default.contents(atPath: path) {
			result["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
		}
	case S_IFDIR:
		result["type"] = "dir"
	case S_IFLNK:
		result["type"] = "link"
		result["target"] = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
	default:
		result["type"] = "other"
	}
	return result
}

private func walk(_ root: SnapshotRoot, into entries: inout [String: [String: Any]]) {
	var info = stat()
	guard lstat(root.path, &info) == 0 else { return }
	if let prefix = root.namePrefix {
		let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
		for name in names where name.hasPrefix(prefix) {
			let path = root.path + "/" + name
			entries[path] = entry(at: path, metaOnly: root.metaOnly)
		}
		return
	}
	entries[root.path] = entry(at: root.path, metaOnly: root.metaOnly)
	guard (info.st_mode & S_IFMT) == S_IFDIR,
		let walker = FileManager.default.enumerator(atPath: root.path)
	else { return }
	while let relative = walker.nextObject() as? String {
		let path = root.path + "/" + relative
		let item = entry(at: path, metaOnly: root.metaOnly)
		entries[path] = item
		if item["type"] as? String == "link" { walker.skipDescendants() }
	}
}

/// `snapshot --out FILE [--token T] [--root PATH]... [--meta-only PATH]...`
func runSnapshot(_ args: [String]) {
	guard let out = value("--out", in: args) else { exit(64) }
	let home = realHome()
	let explicit = values("--root", in: args).map { SnapshotRoot(path: $0, metaOnly: false) }
		+ values("--meta-only", in: args).map { SnapshotRoot(path: $0, metaOnly: true) }
	if explicit.contains(where: { isUnderDotMachman($0.path, home: home) }) { exit(64) }
	var roots = explicit.isEmpty
		? defaultRoots(home: home, token: value("--token", in: args)) : explicit
	roots.removeAll { isUnderDotMachman($0.path, home: home) }
	var entries: [String: [String: Any]] = [:]
	var described: [[String: Any]] = []
	for root in roots {
		walk(root, into: &entries)
		var info = stat()
		described.append([
			"path": root.path, "metaOnly": root.metaOnly,
			"exists": lstat(root.path, &info) == 0,
		])
	}
	let document: [String: Any] = ["version": 1, "roots": described, "entries": entries]
	guard let data = try? JSONSerialization.data(
		withJSONObject: document, options: [.sortedKeys]) else { exit(1) }
	try? data.write(to: URL(fileURLWithPath: out), options: .atomic)
	exit(0)
}

private func loadEntries(_ path: String) -> [String: [String: Any]]? {
	guard let data = FileManager.default.contents(atPath: path),
		let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
	else { return nil }
	return object["entries"] as? [String: [String: Any]]
}

private let comparedFields: [String: [String]] = [
	"file": ["type", "size", "mtimeNs", "mode", "inode", "sha256"],
	"dir": ["type", "mode"],
	"link": ["type", "target"],
	"other": ["type"],
]

private func differences(_ before: [String: Any], _ after: [String: Any]) -> [String] {
	let type = (after["type"] as? String) ?? "other"
	var found: [String] = []
	for field in comparedFields[type] ?? ["type"] {
		let a = before[field].map { "\($0)" } ?? "-"
		let b = after[field].map { "\($0)" } ?? "-"
		if a != b { found.append("\(field) \(a) → \(b)") }
	}
	return found
}

/// `diff --before F --after F --out FILE [--non-lab FILE] [--token T]`
func runDiff(_ args: [String]) {
	guard let beforePath = value("--before", in: args), let afterPath = value("--after", in: args),
		let out = value("--out", in: args),
		let before = loadEntries(beforePath), let after = loadEntries(afterPath)
	else { exit(64) }
	let token = value("--token", in: args)
	let nonLab = value("--non-lab", in: args)
		.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?
		.split(separator: "\n").map(String.init) ?? []
	let pids = nonLab.compactMap { $0.split(separator: " ").first.map(String.init) }
	var lines: [String] = []
	var breach = false
	func report(_ what: String, _ path: String) {
		let named = token.map { path.contains("Machman.test-" + $0) || path.contains("/mml." + $0) }
			?? false
		if !pids.isEmpty && !named {
			lines.append("WARN snapshot \(what) (a non-lab Machman process ran: "
				+ pids.joined(separator: ",") + ")")
		} else {
			lines.append("BREACH snapshot \(what)")
			breach = true
		}
	}
	for path in Set(before.keys).union(after.keys).sorted() {
		switch (before[path], after[path]) {
		case (nil, .some): report("added \(path)", path)
		case (.some, nil): report("removed \(path)", path)
		case (.some(let a), .some(let b)):
			let found = differences(a, b)
			if !found.isEmpty { report("changed \(path) " + found.joined(separator: "; "), path) }
		default: break
		}
	}
	if lines.isEmpty { lines = ["OK snapshot"] }
	emit(lines, to: out)
	exit(breach ? 3 : 0)
}
