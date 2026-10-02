//
//  TerminalProfileTests.swift
//  MachmanUITests
//
//  The profile model's own rules. Scrollback goes straight into SwiftTerm's Buffer.init, which
//  traps on a negative line count and allocates per line of a huge one (P35), so no write and
//  no stored file may hand it a value outside TerminalProfile.scrollbackRange.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanUI

struct TerminalProfileTests {
	private func decode(_ json: String) throws -> TerminalProfile {
		try JSONDecoder().decode(TerminalProfile.self, from: Data(json.utf8))
	}

	@Test func initClampsScrollback() {
		#expect(TerminalProfile(name: "a", scrollback: -1000).scrollback == 0)
		#expect(TerminalProfile(name: "b", scrollback: 50_000_000).scrollback == 100_000)
		#expect(TerminalProfile(name: "c", scrollback: 60_000).scrollback == 60_000)
	}

	// The Settings field writes through a key path, not init.
	@Test func everyWriteClampsScrollback() {
		var profile = TerminalProfile(name: "a")
		profile[keyPath: \.scrollback] = -5
		#expect(profile.scrollback == 0)
		profile.scrollback = 1 << 40
		#expect(profile.scrollback == 100_000)
		#expect(profile.startupSignature.scrollback == 100_000)
	}

	@Test func aStoredValueOutOfRangeLoadsClamped() throws {
		#expect(try decode(#"{"name": "a", "scrollback": -1000}"#).scrollback == 0)
		#expect(try decode(#"{"name": "b", "scrollback": 50000000}"#).scrollback == 100_000)
	}

	// The crash repeated on every relaunch: the bad value was already in the file.
	@MainActor
	@Test func aStoreWithANegativeScrollbackLoadsUsable() throws {
		let url = TestEnvironment.scratchURL
			.appendingPathComponent("tp-\(UUID().uuidString)")
			.appendingPathComponent("TerminalProfiles.json")
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		let json = """
			{"profiles": [{"id": "\(TerminalProfile.defaultID)", "name": "OneDark",
			  "scrollback": -1000}]}
			"""
		try Data(json.utf8).write(to: url)
		#expect(TerminalProfileStore(fileURL: url).defaultProfile.scrollback == 0)
	}
}
