//
//  FileLengthLintTests.swift
//  MachmanAPITests
//
//  Q36: a source file past about 800 lines has taken on more than one responsibility —
//  LocalMachman, RoutingMachman and its host supervisor, and VMConfig had, until they were split
//  by area. Every product Swift file stays at or under the limit: one over it is split by
//  responsibility, or waits on the list below with its reason (and leaves it once it is under).
//

import Foundation
import Testing
import MachmanTestSupport

// L1: lint (repo files).
struct FileLengthLintTests {
	static let limit = 800

	// Product code: everything that ships (tests, tools and scripts are not product).
	static let roots = ["MachmanKit/Sources", "MachmanAgent", "MachmanVMHost", "MachmanDesktop"]

	// Files over the limit that wait for their split, each with its reason.
	static let waiting: [String: String] = [:]

	// Lines as wc -l counts them, plus an unterminated last one.
	static func lineCount(_ text: String) -> Int {
		let newlines = text.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
		return text.isEmpty || text.hasSuffix("\n") ? newlines : newlines + 1
	}

	@Test("Q36: no product source file grows past 800 lines")
	func noSourceFileGrowsPastTheLimit() throws {
		let files = RepoFiles.files(under: Self.roots, extension: "swift")
		#expect(files.count > 200, "the scan found too few files")
		var over: [String] = []
		for file in files {
			let path = RepoFiles.relativePath(file)
			let lines = Self.lineCount(try String(contentsOf: file, encoding: .utf8))
			if lines > Self.limit, Self.waiting[path] == nil {
				over.append("\(path): \(lines) lines")
			}
		}
		#expect(over.isEmpty, "split by responsibility:\n\(over.joined(separator: "\n"))")
	}

	@Test("Q36: a file waiting for its split is still over 800 lines")
	func everyWaitingFileIsStillOver() throws {
		for path in Self.waiting.keys.sorted() {
			let lines = Self.lineCount(try RepoFiles.text(path))
			#expect(lines > Self.limit, "\(path) is \(lines) lines: drop it from the list")
		}
	}
}
