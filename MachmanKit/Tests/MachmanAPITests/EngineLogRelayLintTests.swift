//
//  EngineLogRelayLintTests.swift
//  MachmanAPITests
//
//  E69: a log event is written to the unified log once, by the process it comes from — a
//  vmhost's by the vmhost (the agent passes it on without writing it again). The desktop
//  wrote every one it received as well, so each VM warning read three times under one
//  subsystem. Nothing desktop-side maps a received log event onto a logger type.
//

import Foundation
import Testing
import MachmanTestSupport

// L1: lint (repo files).
struct EngineLogRelayLintTests {
	@Test("E69: the desktop relays engine log lines without writing them to the log")
	func theDesktopRelaysEngineLogLinesWithoutWritingThem() throws {
		let files = RepoFiles.files(
			under: [
				"MachmanKit/Sources/MachmanDesktopCore", "MachmanKit/Sources/MachmanDesktopUI",
				"MachmanDesktop",
			],
			extension: "swift")
		#expect(files.count > 40, "the scan found too few files")
		let pattern = try NSRegularExpression(pattern: #"\.logType\b"#)
		var hits: [RepoFiles.Match] = []
		for file in files {
			let text = try String(contentsOf: file, encoding: .utf8)
			hits += RepoFiles.scan(path: RepoFiles.relativePath(file), text: text, pattern: pattern)
		}
		#expect(hits.isEmpty, "\(hits.map(\.description).joined(separator: "\n"))")
	}
}
