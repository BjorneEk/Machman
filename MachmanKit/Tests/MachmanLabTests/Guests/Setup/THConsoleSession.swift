//
//  THConsoleSession.swift
//  MachmanLabTests
//
//  One interactive command on a logged-in console, as a person types it: the command goes in
//  with an exit marker after it, the test answers the prompts that come (lines or raw keys)
//  and finishes on the marker. The output is read back from the console's transcript, which
//  keeps every byte the guest sent (escape sequences included; CR dropped), so glyph and
//  colour rows look at what reached the terminal.
//

import Foundation

/// Raw keys for the installer's arrow menus.
enum THKey {
	static let up: [UInt8] = [0x1B, 0x5B, 0x41]
	static let down: [UInt8] = [0x1B, 0x5B, 0x42]
	static let space: [UInt8] = [0x20]
	static let enter: [UInt8] = [0x0D]
	static let q: [UInt8] = [0x71]
}

final class THConsoleSession: @unchecked Sendable {
	let console: LabConsole
	let marker: String
	private var offset: UInt64 = 0

	init(_ console: LabConsole) {
		self.console = console
		marker = "TH\(THCounter.next())Q"
	}

	/// Sends `command` followed by the exit marker (split-quoted, so the echo never matches).
	func start(_ command: String) throws {
		offset = Self.size(of: console.transcriptPath)
		let split = marker.dropLast(1)
		try console.send("\(command); echo '\(split)''Q' $?")
	}

	@discardableResult
	func expect(_ pattern: String, timeout: Duration = .seconds(120)) async throws -> [String] {
		try await console.expect(pattern, timeout: timeout)
	}

	/// Waits for `pattern`, then types `reply` and Enter.
	func answer(_ pattern: String, _ reply: String, timeout: Duration = .seconds(120))
		async throws {
		try await console.expect(pattern, timeout: timeout)
		try await Task.sleep(for: .milliseconds(200))
		try console.send(reply)
	}

	/// Raw key bytes (arrow menus read single bytes), with a pause after each.
	func keys(_ keys: [[UInt8]]) async throws {
		for key in keys {
			try console.sendRaw(key)
			try await Task.sleep(for: .milliseconds(400))
		}
	}

	/// Waits for the marker; returns the exit status and the cleaned output since start.
	func finish(timeout: Duration = .seconds(300)) async throws -> (status: Int32, output: String) {
		let groups = try await console.expect("\(marker) (\\d+)\\s*$", timeout: timeout)
		let status = Int32(groups[1]) ?? -1
		return (status, Self.clean(String(decoding: try await rawUntilMarker(), as: UTF8.self)))
	}

	/// The bytes the guest sent since start, up to the marker line (CR dropped, escapes
	/// kept), without the echoed command line.
	func raw() async throws -> [UInt8] { try await rawUntilMarker() }

	private func rawUntilMarker() async throws -> [UInt8] {
		let needle = Array("\(marker) ".utf8)
		let deadline = ContinuousClock.now + .seconds(5)
		while true {
			let bytes = Self.read(console.transcriptPath, from: offset)
			if let end = Self.index(of: needle, in: bytes) {
				var slice = Array(bytes[..<end])
				// The echo of the typed command (one line; a wrapped echo has no newline).
				if let firstNewline = slice.firstIndex(of: 0x0A) {
					slice.removeSubrange(...firstNewline)
				}
				return slice
			}
			if ContinuousClock.now >= deadline { return bytes }
			try await Task.sleep(for: .milliseconds(100))
		}
	}

	private static func size(of path: String) -> UInt64 {
		((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?
			.uint64Value ?? 0
	}

	private static func read(_ path: String, from offset: UInt64) -> [UInt8] {
		guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
		defer { try? handle.close() }
		try? handle.seek(toOffset: offset)
		return Array((try? handle.readToEnd()) ?? Data())
	}

	private static func index(of needle: [UInt8], in bytes: [UInt8]) -> Int? {
		guard bytes.count >= needle.count else { return nil }
		for start in 0...(bytes.count - needle.count)
		where bytes[start] == needle[0] && Array(bytes[start..<start + needle.count]) == needle {
			return start
		}
		return nil
	}

	private static let escapes = try! NSRegularExpression(
		pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*\u{07}|\u{1B}[()][0-9A-Za-z]")

	/// `text` without terminal escape sequences.
	static func clean(_ text: String) -> String {
		let range = NSRange(text.startIndex..., in: text)
		return escapes.stringByReplacingMatches(in: text, range: range, withTemplate: "")
	}
}
