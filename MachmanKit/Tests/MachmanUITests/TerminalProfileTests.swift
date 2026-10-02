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

	// P31: every resize step costs SwiftTerm in proportion to the capacity.
	@Test func newProfilesKeepTenThousandLines() throws {
		#expect(TerminalProfile(name: "a").scrollback == 10_000)
		#expect(TerminalProfile.oneDarkDefault.scrollback == 10_000)
		#expect(try decode(#"{"name": "a"}"#).scrollback == 10_000)
		#expect(try decode(#"{"name": "a", "scrollback": "deep"}"#).scrollback == 10_000)
	}

	// Every saved profile carried the old default, so a new default alone reached nobody.
	@Test func theOldDefaultMovesToTheNewOne() throws {
		#expect(try decode(#"{"name": "a", "scrollback": 500000}"#).scrollback == 10_000)
		#expect(try decode(#"{"name": "b", "scrollback": 250000}"#).scrollback == 100_000)
		#expect(try decode(#"{"name": "c", "scrollback": 60000}"#).scrollback == 60_000)
	}

	// P38: what an open terminal takes on at once — and nothing a Reload is for.
	@Test func liveSettingsCoverOnlyTheLiveFields() {
		let base = TerminalProfile(name: "a")
		var startupOnly = base
		startupOnly.scrollback = 2_000
		startupOnly.cursor = .bar
		startupOnly.name = "renamed"
		#expect(startupOnly.liveSettings == base.liveSettings)
		var font = base
		font.fontSize += 1
		#expect(font.liveSettings != base.liveSettings)
		var colors = base
		colors.colors.background = "#123456"
		#expect(colors.liveSettings != base.liveSettings)
	}

	// The crash repeated on every relaunch: the bad value was already in the file.
	@MainActor
	@Test func aStoreWithANegativeScrollbackLoadsUsable() throws {
		let url = try storeFile(scrollback: -1000)
		#expect(TerminalProfileStore(fileURL: url).defaultProfile.scrollback == 0)
	}

	@MainActor
	@Test func aStoreSavedWithTheOldDefaultLoadsTheNewOne() throws {
		let url = try storeFile(scrollback: 500_000)
		#expect(TerminalProfileStore(fileURL: url).defaultProfile.scrollback == 10_000)
	}

	private func storeFile(scrollback: Int) throws -> URL {
		let url = TestEnvironment.scratchURL
			.appendingPathComponent("tp-\(UUID().uuidString)")
			.appendingPathComponent("TerminalProfiles.json")
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		let json = """
			{"profiles": [{"id": "\(TerminalProfile.defaultID)", "name": "OneDark",
			  "scrollback": \(scrollback)}]}
			"""
		try Data(json.utf8).write(to: url)
		return url
	}
}
