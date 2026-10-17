//
//  LabRetry.swift
//  MachmanLabTests
//
//  The retries the harness rides over, made visible: each one records a warning issue on the
//  running test (shown under its result, never failing it) besides its lab-log line, so a
//  retry that starts to happen often reads as what it may be, a product bug, not as nothing.
//

import Foundation
import MachmanAPI
import Testing

enum LabRetry {
	/// Logs `what` and records it as a warning on the running test, at the caller's line (where
	/// the retry happened), not this one. Plain literals rather than #_sourceLocation, which
	/// would need every caller's file to import Testing.
	static func note(
		_ what: String, fileID: String = #fileID, filePath: String = #filePath, line: Int = #line,
		column: Int = #column
	) {
		let place = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
		note(what, at: place)
	}

	private static func note(_ what: String, at place: SourceLocation) {
		MachmanLogger.log(.passiveWarning, "lab: " + what)
		Issue.record(Comment(rawValue: what), severity: .warning, sourceLocation: place)
	}

	/// The agent's refusal while it settles a stop: it counted a VM that just listed stopped
	/// as hosted until the vmhost's exit reached it ("Stop <VM> before …", E52). It waits the
	/// exit out now, so a retry noted here is a regression to look at.
	static func isSettling(_ error: Error) -> Bool {
		(error as? MachmanError)?.code == .invalidState
	}

	/// `body`, retried every 250 ms for `seconds` while `retry` says the error is the agent
	/// settling a stop; the first retry is noted on the test, at the caller's line.
	static func settled<T>(
		_ what: String, seconds: Int = 15, retry: (Error) -> Bool = isSettling,
		fileID: String = #fileID, filePath: String = #filePath, line: Int = #line,
		column: Int = #column, _ body: () async throws -> T
	) async throws -> T {
		let deadline = ContinuousClock.now + .seconds(seconds)
		var noted = false
		while true {
			do {
				return try await body()
			} catch where retry(error) && ContinuousClock.now < deadline {
				if !noted {
					note(
						"\(what) was refused while a stop settled, retrying: \(error)",
						at: SourceLocation(
							fileID: fileID, filePath: filePath, line: line, column: column))
					noted = true
				}
				try await Task.sleep(for: .milliseconds(250))
			}
		}
	}
}
