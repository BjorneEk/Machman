//
//  LabStep.swift
//  MachmanLabTests
//
//  A harness wait that runs long, narrated in the lab log: a line once it has waited 5 s, a
//  heartbeat every 15 s with what it has seen so far, and a line when it ends. A wait that ends
//  sooner logs nothing. lab.sh's progress follower (scripts/lab/progress.py) shows these lines
//  and names the step a quiet run is in; LabLog.entries leaves them out, so no test's pattern
//  ever matches a narration of its own wait.
//

import Foundation
import MachmanAPI
import Testing

enum LabStep {
	/// What every narration line carries after MachmanLogger's "[log] ".
	static let marker = "lab: step "

	/// Runs `body`, narrated as `what` (`seen` adds the latest thing the wait has seen, e.g. a
	/// console's last line, to each heartbeat).
	static func run<T>(
		_ what: String, seen: (@Sendable () -> String?)? = nil,
		after quiet: Duration = .seconds(5), every beat: Duration = .seconds(15),
		_ body: () async throws -> T
	) async throws -> T {
		let narration = Narration(what, seen: seen, after: quiet, every: beat)
		do {
			let value = try await body()
			narration.end(nil)
			return value
		} catch {
			narration.end(error)
			throw error
		}
	}

	static func run<T>(
		_ what: String, seen: (@Sendable () -> String?)? = nil,
		after quiet: Duration = .seconds(5), every beat: Duration = .seconds(15),
		_ body: () async -> T
	) async -> T {
		let narration = Narration(what, seen: seen, after: quiet, every: beat)
		let value = await body()
		narration.end(nil)
		return value
	}

	/// The running test's id ("R2" of "R2: …"), else its function name.
	static var testLabel: String {
		guard let test = Test.current else { return "-" }
		let name = test.displayName ?? test.name
		if let colon = name.firstIndex(of: ":") {
			let id = name[..<colon]
			if !id.isEmpty, id.count <= 16, !id.contains(" ") { return String(id) }
		}
		return test.name
	}

	/// "45 s", "2m05s".
	static func format(_ elapsed: Duration) -> String {
		let seconds = Int(elapsed.components.seconds)
		return seconds < 60
			? "\(seconds) s" : String(format: "%dm%02ds", seconds / 60, seconds % 60)
	}

	/// One narrated wait. Its lines are logged under a lock that `end` also takes, so no start
	/// or heartbeat line follows the end line.
	private final class Narration: @unchecked Sendable {
		private let label = LabStep.testLabel
		private let what: String
		private let started = ContinuousClock.now
		private let lock = NSLock()
		private var begun = false
		private var finished = false
		private var narrator: Task<Void, Never>?

		init(
			_ what: String, seen: (@Sendable () -> String?)?, after quiet: Duration,
			every beat: Duration
		) {
			self.what = what
			narrator = Task { [self] in
				guard (try? await Task.sleep(for: quiet)) != nil else { return }
				say("▸", seen: seen)
				while (try? await Task.sleep(for: beat)) != nil { say("…", seen: seen) }
			}
		}

		func end(_ error: Error?) {
			narrator?.cancel()
			lock.withLock {
				finished = true
				guard begun else { return }
				let outcome = error.map { "✘ \(what) — \(elapsed): \($0)" }
					?? "✓ \(what) — \(elapsed)"
				MachmanLogger.log(.log, LabStep.marker + "\(label) \(outcome)")
			}
		}

		private var elapsed: String { LabStep.format(started.duration(to: .now)) }

		private func say(_ glyph: String, seen: (@Sendable () -> String?)?) {
			let latest = seen?()?.trimmingCharacters(in: .whitespacesAndNewlines)
			lock.withLock {
				guard !finished else { return }
				begun = true
				var line = LabStep.marker + "\(label) \(glyph) \(what) — \(elapsed)"
				if let latest, !latest.isEmpty { line += " · seen: \(latest.prefix(160))" }
				MachmanLogger.log(.log, line)
			}
		}
	}
}
