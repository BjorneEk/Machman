//
//  SourceScan.swift
//  MachmanCoreTests
//
//  Read-only scans of the repo's Swift sources for the lints (AgentQuietLintTests,
//  TestModeSeamInventoryTests): the worktree this test was built from, never written.
//

import Foundation

enum SourceScan {
	// MachmanKit/Tests/MachmanCoreTests/<this file> → the repo.
	static let repo = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent().deletingLastPathComponent()
		.deletingLastPathComponent().deletingLastPathComponent()

	struct Hit: CustomStringConvertible {
		let file: String
		let line: Int
		let text: String
		var description: String { "\(file):\(line): \(text)" }
	}

	// Swift files under `directory` (repo-relative), recursively, sorted.
	static func swiftFiles(under directory: String) -> [String] {
		let root = repo.appendingPathComponent(directory)
		let found = FileManager.default.enumerator(atPath: root.path)?
			.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") } ?? []
		return found.sorted().map { directory + "/" + $0 }
	}

	static func lines(of file: String) throws -> [String] {
		try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
			.components(separatedBy: "\n")
	}

	// The code part of a line: anything after `//` is a comment.
	static func code(_ line: String) -> String {
		line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
	}

	// Lines of `files` whose code matches `pattern`.
	static func hits(_ pattern: String, in files: [String]) throws -> [Hit] {
		let regex = try Regex(pattern)
		var found: [Hit] = []
		for file in files {
			for (index, line) in try lines(of: file).enumerated()
			where code(line).contains(regex) {
				found.append(Hit(
					file: file, line: index + 1, text: line.trimmingCharacters(in: .whitespaces)))
			}
		}
		return found
	}
}
