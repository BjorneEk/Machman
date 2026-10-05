//
//  SerialLogModeToleranceTests.swift
//  MachmanAPITests
//
//  D26: an unrecognized SerialLogMode decoded as resetOnBoot and was ENCODED as resetOnBoot,
//  so the next save rewrote a newer Machman's setting. The mode now rides through as written;
//  this build logs it like the default, and setting a mode replaces it.
//

import Testing
import Foundation
import MachmanAPI

struct SerialLogModeToleranceTests {
	private func encoded(_ config: SerialLogConfig) throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		return String(decoding: try encoder.encode(config), as: UTF8.self)
	}

	@Test func aNewerModeReadsAsTheDefaultAndEncodesAsItself() throws {
		let config = try JSONDecoder().decode(
			SerialLogConfig.self, from: Data(#"{"maxBytes":5,"mode":"rotate"}"#.utf8))
		#expect(config.mode == .resetOnBoot)
		#expect(config.rawMode == "rotate")
		#expect(config.maxBytes == 5)
		#expect(try encoded(config) == #"{"maxBytes":5,"mode":"rotate"}"#)
	}

	@Test func settingAModeReplacesANewerOne() throws {
		var config = try JSONDecoder().decode(
			SerialLogConfig.self, from: Data(#"{"mode":"rotate"}"#.utf8))
		config.mode = .continuous
		#expect(config == SerialLogConfig(mode: .continuous))
		#expect(try encoded(config) == #"{"mode":"continuous"}"#)
	}

	@Test func anAbsentModeStillDefaults() throws {
		let config = try JSONDecoder().decode(SerialLogConfig.self, from: Data("{}".utf8))
		#expect(config == SerialLogConfig())
		#expect(try encoded(config) == #"{"mode":"resetOnBoot"}"#)
	}
}
