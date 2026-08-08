//
//  MachmanLoggerTests.swift
//  MachmanTests
//

import Testing
import MachmanAPI

struct MachmanLoggerTests {
	@Test func wireLogLevelsMapToLoggerTypes() {
		#expect(LogLevel.message.logType == .log)
		#expect(LogLevel.warning.logType == .passiveWarning)
		#expect(LogLevel.error.logType == .passiveError)
	}

	@Test func mirrorTagsAreStable() {
		// The raw values are the bracketed tags in terminal output — grep targets, keep stable.
		#expect(MachmanLogType.log.rawValue == "log")
		#expect(MachmanLogType.passiveWarning.rawValue == "warning")
		#expect(MachmanLogType.passiveError.rawValue == "error")
		#expect(MachmanLogType.interactionWarning.rawValue == "interaction-warning")
		#expect(MachmanLogType.interactionError.rawValue == "interaction-error")
	}
}
