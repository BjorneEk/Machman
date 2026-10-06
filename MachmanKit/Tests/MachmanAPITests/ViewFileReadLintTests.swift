//
//  ViewFileReadLintTests.swift
//  MachmanAPITests
//
//  P11: a view's body runs on the main actor at every render, so a file read there stalls
//  the UI (the SSH inspector read this Mac's public key on every render; on a slow or
//  network volume every read is a hitch). Desktop views read files through an async helper
//  off the main actor instead (SSHPublicKey.read and the like).
//

import Foundation
import Testing
import MachmanTestSupport

// L1: lint (repo files).
struct ViewFileReadLintTests {
	static let reads = [
		#"String\(contentsOfFile:"#, #"String\(contentsOf:"#, #"Data\(contentsOf:"#,
		#"\.contents\(atPath:"#, #"FileHandle\(forReadingAtPath:"#,
	].map { try! NSRegularExpression(pattern: $0) }

	@Test("P11: no desktop view reads a file synchronously")
	func noViewReadsAFile() throws {
		let files = RepoFiles.files(
			under: ["MachmanKit/Sources/MachmanDesktopUI"], extension: "swift")
		#expect(files.count > 40, "the scan found too few files")
		var hits: [RepoFiles.Match] = []
		for file in files {
			let text = try String(contentsOf: file, encoding: .utf8)
			let path = RepoFiles.relativePath(file)
			for pattern in Self.reads {
				hits += RepoFiles.scan(path: path, text: text, pattern: pattern)
			}
		}
		#expect(hits.isEmpty, "\(hits.map(\.description).joined(separator: "\n"))")
	}
}
