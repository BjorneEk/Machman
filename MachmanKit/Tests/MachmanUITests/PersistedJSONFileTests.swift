import Testing
import Foundation
import MachmanTestSupport
import MachmanUI

// A settings file that can't be read is set aside, never overwritten (P19).
@MainActor
struct PersistedJSONFileTests {
	private func freshDir() throws -> URL {
		let dir = TestEnvironment.scratchURL.appendingPathComponent("pjf-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	private func file(_ url: URL) -> PersistedJSONFile<[String: Int]> {
		PersistedJSONFile(url: url, label: "PersistedJSONFileTests", queueLabel: "pjf.tests")
	}

	@Test func anAbsentFileLoadsNothingAndSetsNothingAside() throws {
		let url = try freshDir().appendingPathComponent("Settings.json")
		let persisted = file(url)
		#expect(persisted.load() == nil)
		#expect(persisted.backupURL == nil)
	}

	@Test func aReadableFileRoundTrips() throws {
		let url = try freshDir().appendingPathComponent("Settings.json")
		let persisted = file(url)
		persisted.save(["panes": 2])
		persisted.flush()
		#expect(file(url).load() == ["panes": 2])
	}

	@Test func anEarlierBackupIsNeverOverwritten() throws {
		let dir = try freshDir()
		let url = dir.appendingPathComponent("Settings.json")
		let first = dir.appendingPathComponent("Settings.json.bak")
		try Data("old".utf8).write(to: first)
		try Data("garbage".utf8).write(to: url)
		let persisted = file(url)
		#expect(persisted.load() == nil)
		#expect(persisted.backupURL?.lastPathComponent == "Settings.json.bak.2")
		#expect(try String(contentsOf: first, encoding: .utf8) == "old")
		let second = dir.appendingPathComponent("Settings.json.bak.2")
		#expect(try String(contentsOf: second, encoding: .utf8) == "garbage")
		#expect(!FileManager.default.fileExists(atPath: url.path))
	}
}
