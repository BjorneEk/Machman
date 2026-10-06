//
//  LabStepTests.swift
//  MachmanLabTests
//
//  L2 harness — LabStep's narration of long waits, read back from the run's lab log as
//  lab.sh's progress follower reads it (LabLog itself leaves narrations out).
//

import Foundation
import MachmanAPI
import Testing

@Suite("Lab step narration", .serialized, .enabled(if: Lab.runs(.harness)))
struct LabStepTests {
	@Test("Q18: a slow lab wait logs its start, heartbeats with what it saw, and its end")
	func slowWaitIsNarrated() async throws {
		let tag = "slow-\(UUID().uuidString.prefix(8))"
		let mark = LabLog.mark()
		try await LabStep.run(
			tag, seen: { "the console's last line" }, after: .milliseconds(200),
			every: .milliseconds(300)
		) {
			try await Task.sleep(for: .milliseconds(1200))
		}
		let lines = try await narrations(of: tag, after: mark, through: "✓")
		#expect(lines.first?.contains("lab: step ▸ \(tag) — ") == true)
		#expect(lines.contains {
			$0.contains("lab: step … \(tag) — ")
				&& $0.contains("· seen: the console's last line")
		})
		#expect(lines.last?.contains("lab: step ✓ \(tag) — 1 s") == true)
	}

	@Test("Q18: a lab wait that ends within its quiet time logs nothing")
	func quickWaitIsQuiet() async throws {
		let tag = "quick-\(UUID().uuidString.prefix(8))"
		let mark = LabLog.mark()
		await LabStep.run(tag, after: .seconds(2)) {}
		try await Task.sleep(for: .seconds(3))
		MachmanLogger.log(.log, "lab: sentinel \(tag)")
		_ = try await LabLog.waitFor("lab: sentinel \(tag)", after: mark)
		#expect(Self.messages(after: mark).filter { $0.contains(LabStep.marker) }
			.allSatisfy { !$0.contains(tag) })
	}

	@Test("Q18: a failed lab wait logs its error, and LabLog's readers never see narrations")
	func failedWaitNamesItsError() async throws {
		let tag = "failed-\(UUID().uuidString.prefix(8))"
		let mark = LabLog.mark()
		await #expect(throws: LabError.self) {
			try await LabStep.run(tag, after: .milliseconds(100)) {
				try await Task.sleep(for: .milliseconds(400))
				throw LabError.specInvalid("no such thing")
			}
		}
		let lines = try await narrations(of: tag, after: mark, through: "✘")
		#expect(lines.last?.contains("✘ \(tag) — 0 s: ") == true)
		#expect(lines.last?.contains("no such thing") == true)
		#expect(LabLog.entries(after: mark).allSatisfy {
			!$0.eventMessage.contains(LabStep.marker)
		})
	}

	@Test("Q18: a step's elapsed time reads in seconds, then minutes and seconds")
	func elapsedFormat() {
		#expect(LabStep.format(.milliseconds(900)) == "0 s")
		#expect(LabStep.format(.seconds(59)) == "59 s")
		#expect(LabStep.format(.seconds(125)) == "2m05s")
	}

	// The narrations of `tag` after `mark`, once the one carrying `glyph` arrived (10 s).
	private func narrations(
		of tag: String, after mark: UInt64, through glyph: String
	) async throws -> [String] {
		let deadline = ContinuousClock.now + .seconds(10)
		while true {
			let lines = Self.messages(after: mark).filter {
				$0.contains(LabStep.marker) && $0.contains(" \(tag) — ")
			}
			if lines.contains(where: { $0.contains("\(glyph) \(tag)") }) { return lines }
			if ContinuousClock.now >= deadline {
				throw LabError.logTimeout(pattern: "\(glyph) \(tag)")
			}
			try await Task.sleep(for: .milliseconds(200))
		}
	}

	// Every message in the lab log after `mark`, narrations included.
	private static func messages(after mark: UInt64) -> [String] {
		guard let handle = FileHandle(forReadingAtPath: Lab.logPath) else { return [] }
		defer { try? handle.close() }
		try? handle.seek(toOffset: mark)
		let data = (try? handle.readToEnd()) ?? Data()
		return data.split(separator: UInt8(ascii: "\n")).compactMap {
			(try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])?["eventMessage"]
				as? String
		}
	}
}
