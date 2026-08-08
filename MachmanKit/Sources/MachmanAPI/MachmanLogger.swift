//
//  MachmanLogger.swift
//  MachmanAPI
//
//  Every process's diagnostics funnel. Two sinks per call:
//    - os.Logger (subsystem = suite id, category = process name): persisted in the unified
//      log, attributed to the emitting app, readable after exit via `log show` or
//      `log stream --predicate 'subsystem == "<suite>"'`.
//    - a stdout/stderr mirror, "<process> [<tag>] message", for plain-terminal dev runs.
//      The mirror prints unredacted — `privacy` governs the persisted store only.
//  Never bare print for diagnostics: block-buffered off-tty, it simply vanishes.
//

import Foundation
import os

public enum MachmanLogType: String, Sendable {
	case log = "log"                                    // info about what is going on
	case passiveWarning = "warning"                     // engine/telemetry, nobody asked
	case passiveError = "error"
	case interactionWarning = "interaction-warning"     // a user-initiated action went sideways
	case interactionError = "interaction-error"
}

public enum MachmanLogPrivacy: Sendable {
	case `public`
	case `private`
}

public enum MachmanLogger {
	// Cached once: subsystem/category never change after launch. os.Logger is Sendable and
	// thread-safe, so this is callable from any actor or thread.
	private static let logger = Logger(
		subsystem: MachmanPaths.suiteIdentifier(),
		category: ProcessInfo.processInfo.processName)
	private static let processName = ProcessInfo.processInfo.processName

	public static func log(
		_ type: MachmanLogType, _ message: String, privacy: MachmanLogPrivacy = .public
	) {
		let tag = type.rawValue
		let isError: Bool
		switch type {
		case .passiveError, .interactionError: isError = true
		case .log, .passiveWarning, .interactionWarning: isError = false
		}
		// OSLog wants privacy as a LITERAL in the interpolation — branch, don't pass it.
		// log + warnings persist at .default (survive exit); errors at .error.
		switch (isError, privacy) {
		case (true, .public):
			logger.error("[\(tag, privacy: .public)] \(message, privacy: .public)")
		case (true, .private):
			logger.error("[\(tag, privacy: .public)] \(message, privacy: .private)")
		case (false, .public):
			logger.log("[\(tag, privacy: .public)] \(message, privacy: .public)")
		case (false, .private):
			logger.log("[\(tag, privacy: .public)] \(message, privacy: .private)")
		}
		mirror(type, isError: isError, message)
	}

	// stdout for .log, stderr for everything above; one Data write so lines don't interleave.
	private static func mirror(_ type: MachmanLogType, isError: Bool, _ message: String) {
		let line = "\(processName) [\(type.rawValue)] \(message)\n"
		let handle: FileHandle = (type == .log) ? .standardOutput : .standardError
		handle.write(Data(line.utf8))
	}
}

// Wire log events map onto the passive logger types (used by EventBus's guaranteed sink and
// by the desktop's relay of received .log events).
public extension LogLevel {
	var logType: MachmanLogType {
		switch self {
		case .message: return .log
		case .warning: return .passiveWarning
		case .error: return .passiveError
		}
	}
}
