//
//  LabLog.swift
//  MachmanLabTests
//
//  The unified-log lines of the lab's suite: lab.sh streams them as ndjson into
//  Lab.logPath (the stdio of an NSWorkspace-launched agent is not captured). MachmanLogger
//  lines read "[log] ...", so patterns are never anchored at the start.
//

import Foundation

enum LabLog {
	struct Entry: Decodable, Sendable {
		let eventMessage: String
		let processID: Int?
		let processImagePath: String?
		let subsystem: String?
		let category: String?
		let timestamp: String?

		var process: String? { processImagePath.map { ($0 as NSString).lastPathComponent } }
	}

	/// The log's size now: lines written later are "after" it.
	static func mark(path: String = Lab.logPath) -> UInt64 {
		let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber
		return size?.uint64Value ?? 0
	}

	/// Every complete line (ending in a newline) after `mark` that decodes.
	static func entries(after mark: UInt64 = 0, path: String = Lab.logPath) -> [Entry] {
		guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
		defer { try? handle.close() }
		try? handle.seek(toOffset: mark)
		let data = (try? handle.readToEnd()) ?? Data()
		guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
		let decoder = JSONDecoder()
		return data[data.startIndex...end].split(separator: UInt8(ascii: "\n")).compactMap {
			try? decoder.decode(Entry.self, from: Data($0))
		}
	}

	static func count(_ pattern: String, after: UInt64 = 0, path: String = Lab.logPath) -> Int {
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
		return entries(after: after, path: path).filter {
			regex.firstMatch(in: $0.eventMessage, range: NSRange($0.eventMessage.startIndex..., in: $0.eventMessage))
				!= nil
		}.count
	}

	/// Waits for a line whose message matches `pattern` (optionally from one process).
	static func waitFor(
		_ pattern: String, after: UInt64 = 0, process: String? = nil,
		timeout: Duration = .seconds(20), path: String = Lab.logPath
	) async throws -> Entry {
		let regex = try NSRegularExpression(pattern: pattern)
		let deadline = ContinuousClock.now + timeout
		while true {
			let hit = entries(after: after, path: path).first { entry in
				let range = NSRange(entry.eventMessage.startIndex..., in: entry.eventMessage)
				return regex.firstMatch(in: entry.eventMessage, range: range) != nil
					&& (process == nil || entry.process == process)
			}
			if let hit { return hit }
			if ContinuousClock.now >= deadline { throw LabError.logTimeout(pattern: pattern) }
			try await Task.sleep(for: .milliseconds(200))
		}
	}
}
