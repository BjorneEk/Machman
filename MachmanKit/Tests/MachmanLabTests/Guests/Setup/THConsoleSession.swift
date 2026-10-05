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
	/// The begin and end markers: printed only by the echo commands around the command
	/// (split-quoted in what is typed, so an echoed line — wrapped or not — never matches).
	let begin: String
	let marker: String
	private var offset: UInt64 = 0

	init(_ console: LabConsole) {
		self.console = console
		let n = THCounter.next()
		begin = "THB\(n)"
		marker = "THE\(n)"
	}

	/// Sends `command` between the begin and end markers, the end with the exit status.
	func start(_ command: String) throws {
		offset = Self.size(of: console.transcriptPath)
		try console.send(
			"echo '\(begin.prefix(3))''\(begin.dropFirst(3))'; \(command); "
				+ "echo '\(marker.prefix(3))''\(marker.dropFirst(3))' $?")
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

	/// The installer's questions as a console shows them.
	enum Prompt: String, Sendable {
		/// The numbered feature menu (TERM=dumb): "Toggle numbers …:".
		case toggle
		/// A numbered single choice: "Choose [n]:".
		case choose
		/// The arrow feature menu (space toggles).
		case multi
		/// An arrow single choice.
		case select
		/// "Proceed? [Y/n]".
		case proceed
		/// Any other yes/no question.
		case yesNo
		/// A password (sudo's, doas's, su's).
		case password
	}

	struct Driven {
		var status: Int32
		var output: String
		/// Each question in order, with the text the guest printed before it.
		var prompts: [(prompt: Prompt, before: String)]

		func before(_ prompt: Prompt) -> String? {
			prompts.first { $0.prompt == prompt }?.before
		}

		var kinds: [Prompt] { prompts.map(\.prompt) }
	}

	/// Answers the installer's questions until it exits, as a person keeping the defaults
	/// would: Enter for a menu and a choice, `toggle` (given what was printed before it) for a
	/// numbered menu, `multiKeys` for
	/// the arrow menu, `choose` (given what was printed before it) for a numbered choice,
	/// `proceed` for "Proceed?", `yesNo` for any other yes/no, `password` when sudo, doas or
	/// su asks.
	func drive(
		toggle: @escaping (String) -> String = { _ in "" }, multiKeys: [[UInt8]] = [THKey.enter],
		choose: ((String) -> String)? = nil, proceed: String = "q", yesNo: String = "",
		password: String? = nil, timeout: Duration = .seconds(180)
	) async throws -> Driven {
		let pattern = "(?s:(.*?))(?:"
			+ "(Toggle numbers \\(space-separated\\), empty keeps the selection: *$)"
			+ "|(Choose \\[\\d+\\]: *$)"
			+ "|(\\(arrows, space toggles, enter\\) *$)"
			+ "|(\\(arrows, enter\\) *$)"
			+ "|(Proceed\\? \\[Y/n\\] *$)"
			+ "|(\\[[yY]/[nN]\\] *$)"
			+ "|(\\[sudo\\] password for [^:]*: *$|^doas \\([^)]*\\) password: *$"
			+ "|^Password: *$)"
			+ "|(\(marker) (\\d+)\\s*$))"
		var prompts: [(prompt: Prompt, before: String)] = []
		let deadline = ContinuousClock.now + timeout
		while true {
			let left = deadline - ContinuousClock.now
			guard left > .zero else {
				throw LabError.expectTimeout(pattern: "the installer's end", tail: console.tail)
			}
			let g = try await console.expect(pattern, timeout: left)
			let before = g[1]
			if !g[9].isEmpty {
				let status = Int32(g[10]) ?? -1
				let output = Self.clean(String(decoding: try await rawUntilMarker(), as: UTF8.self))
				return Driven(status: status, output: output, prompts: prompts)
			}
			let prompt: Prompt =
				!g[2].isEmpty ? .toggle : !g[3].isEmpty ? .choose : !g[4].isEmpty ? .multi
				: !g[5].isEmpty ? .select : !g[6].isEmpty ? .proceed
				: !g[7].isEmpty ? .yesNo : .password
			prompts.append((prompt, before))
			try await Task.sleep(for: .milliseconds(300))
			switch prompt {
			case .toggle: try console.send(toggle(before))
			case .choose: try console.send(choose?(before) ?? "")
			case .multi:
				// The menu is drawn after its header: give it a moment before the keys.
				try await Task.sleep(for: .seconds(1))
				try await keys(prompts.filter { $0.prompt == .multi }.count == 1
					? multiKeys : [THKey.enter])
			case .select:
				try await Task.sleep(for: .seconds(1))
				try await keys([THKey.enter])
			case .proceed: try console.send(proceed)
			case .yesNo: try console.send(yesNo)
			case .password:
				guard let password else {
					throw LabError.consoleUnavailable("asked for a password:\n\(before)")
				}
				try console.send(password)
			}
		}
	}

	/// Waits for the marker; returns the exit status and the cleaned output since start.
	func finish(timeout: Duration = .seconds(120)) async throws -> (status: Int32, output: String) {
		let groups = try await console.expect("\(marker) (\\d+)\\s*$", timeout: timeout)
		let status = Int32(groups[1]) ?? -1
		return (status, Self.clean(String(decoding: try await rawUntilMarker(), as: UTF8.self)))
	}

	/// The bytes the command printed: after the begin marker's line, up to the end marker
	/// (CR dropped, escapes kept) — the typed echo, however a line editor wrapped it, is not
	/// part of it.
	func raw() async throws -> [UInt8] { try await rawUntilMarker() }

	private func rawUntilMarker() async throws -> [UInt8] {
		let start = Array("\(begin)\n".utf8)
		let needle = Array("\(marker) ".utf8)
		let deadline = ContinuousClock.now + .seconds(5)
		while true {
			let bytes = Self.read(console.transcriptPath, from: offset)
			if let end = Self.index(of: needle, in: bytes) {
				var slice = Array(bytes[..<end])
				if let first = Self.index(of: start, in: slice) {
					slice.removeSubrange(..<(first + start.count))
				}
				return slice
			}
			if ContinuousClock.now >= deadline { return bytes }
			try await Task.sleep(for: .milliseconds(100))
		}
	}

	/// One command with no questions: its status and output (between the markers).
	static func run(
		_ console: LabConsole, _ command: String, timeout: Duration = .seconds(120)
	) async throws -> (status: Int32, output: String) {
		let s = THConsoleSession(console)
		try s.start(command)
		let groups = try await console.expect(
			"^\(s.begin)\\n(?s:(.*?))^\(s.marker) (\\d+)\\s*$", timeout: timeout)
		var output = groups[1]
		if output.hasSuffix("\n") { output.removeLast() }
		return (Int32(groups[2]) ?? -1, output)
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
