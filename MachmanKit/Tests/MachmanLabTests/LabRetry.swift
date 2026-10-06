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
	/// Logs `what` and records it as a warning on the running test.
	static func note(_ what: String) {
		MachmanLogger.log(.passiveWarning, "lab: " + what)
		Issue.record(Comment(rawValue: what), severity: .warning)
	}

	/// The agent's refusal while it settles a stop: it still counts a VM that just listed
	/// stopped as hosted until the vmhost's exit reaches it ("Stop <VM> before …"), which is
	/// the open bug E52.
	static func isSettling(_ error: Error) -> Bool {
		(error as? MachmanError)?.code == .invalidState
	}

	/// `body`, retried every 250 ms for `seconds` while `retry` says the error is the agent
	/// settling a stop; the first retry is noted on the test.
	static func settled<T>(
		_ what: String, seconds: Int = 15, retry: (Error) -> Bool = isSettling,
		_ body: () async throws -> T
	) async throws -> T {
		let deadline = ContinuousClock.now + .seconds(seconds)
		var noted = false
		while true {
			do {
				return try await body()
			} catch where retry(error) && ContinuousClock.now < deadline {
				if !noted {
					note("\(what) was refused while a stop settled, retrying: \(error)")
					noted = true
				}
				try await Task.sleep(for: .milliseconds(250))
			}
		}
	}
}
