//
//  RepoFiles.swift
//  MachmanTestSupport
//
//  The checkout a test was built from, for lints over its files (build settings, schemes,
//  test sources): found from this file's own path, so a lane worktree lints itself and
//  never the main checkout. Read-only.
//

import Foundation

public enum RepoFiles {
	// The directory holding Machman.xcodeproj and MachmanKit/Package.swift, above this file.
	public static let root: URL = {
		var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
		let manager = FileManager.default
		while dir.path != "/" {
			if manager.fileExists(atPath: dir.appendingPathComponent("Machman.xcodeproj").path),
				manager.fileExists(
					atPath: dir.appendingPathComponent("MachmanKit/Package.swift").path) {
				return dir
			}
			dir = dir.deletingLastPathComponent()
		}
		fatalError("RepoFiles: no Machman checkout above \(#filePath)")
	}()

	// Never walked: build products, package caches, git internals, and the gitignored
	// docs/local (research, demos and scratch, none of it the product).
	static let skippedNames: Set<String> = [
		".build", "DerivedData", ".swiftpm", ".git", "node_modules", "xcuserdata",
	]
	static let skippedPaths: Set<String> = ["docs/local"]

	public static func url(_ relative: String) -> URL {
		relative.isEmpty ? root : root.appendingPathComponent(relative)
	}

	public static func text(_ relative: String) throws -> String {
		try String(contentsOf: url(relative), encoding: .utf8)
	}

	// Every file with `extension` under the given repo-relative directories ("" = the whole
	// checkout), sorted by path.
	public static func files(under directories: [String], extension ext: String) -> [URL] {
		var found: [URL] = []
		let manager = FileManager.default
		let rootPath = root.standardizedFileURL.path
		for directory in directories {
			guard let walker = manager.enumerator(
				at: url(directory), includingPropertiesForKeys: [.isDirectoryKey])
			else { continue }
			for case let file as URL in walker {
				let isDirectory =
					(try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
				if isDirectory {
					let relative = String(file.standardizedFileURL.path
						.dropFirst(rootPath.count)).trimmingCharacters(in: ["/"])
					if skippedNames.contains(file.lastPathComponent)
						|| skippedPaths.contains(relative) {
						walker.skipDescendants()
					}
				} else if file.pathExtension == ext {
					found.append(file)
				}
			}
		}
		return found.sorted { $0.path < $1.path }
	}

	// One matching line: its repo-relative path, 1-based number and text.
	public struct Match: Equatable, Sendable, CustomStringConvertible {
		public let path: String
		public let line: Int
		public let text: String

		public init(path: String, line: Int, text: String) {
			self.path = path
			self.line = line
			self.text = text
		}

		public var description: String { "\(path):\(line): \(text)" }
	}

	// The lines of `text` (a file named `path`) that `pattern` matches — the pure core of a
	// lint, so a test can provoke one with data.
	public static func scan(path: String, text: String, pattern: NSRegularExpression)
		-> [Match] {
		var matches: [Match] = []
		for (index, line) in text.components(separatedBy: "\n").enumerated() {
			let range = NSRange(line.startIndex..., in: line)
			if pattern.firstMatch(in: line, range: range) != nil {
				matches.append(Match(path: path, line: index + 1, text: line))
			}
		}
		return matches
	}

	public static func grep(
		_ pattern: NSRegularExpression, under directories: [String], extension ext: String
	) -> [Match] {
		files(under: directories, extension: ext).flatMap { file -> [Match] in
			guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
			return scan(path: relativePath(file), text: text, pattern: pattern)
		}
	}

	public static func relativePath(_ file: URL) -> String {
		let rootPath = root.standardizedFileURL.path
		let path = file.standardizedFileURL.path
		return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
	}
}
