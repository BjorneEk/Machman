//
//  LabError.swift
//  MachmanLabTests
//
//  What the lab harness throws; each description names what to do next.
//

import Foundation

enum LabError: Error, CustomStringConvertible {
	case seamsMissing
	case agentDidNotStart(String)
	case noTestModeBanner(suite: String)
	case fixtureMissing(name: String)
	case specInvalid(String)
	case guestCap(running: Int)
	case stateTimeout(vm: String, wanted: String, last: String)
	case consoleUnavailable(String)
	case consoleClosed(tail: String)
	case expectTimeout(pattern: String, tail: String)
	case logTimeout(pattern: String)
	case commandFailed(command: String, status: Int32, output: String)
	case controlFailed(String)

	var description: String {
		switch self {
		case .seamsMissing:
			"this build lacks the test-mode seams (r3-tb), so the lab won't launch its agent"
		case .agentDidNotStart(let why):
			"the lab agent didn't start: \(why)"
		case .noTestModeBanner(let suite):
			"the lab agent never logged 'test mode: agent under \(suite)'; it was killed"
		case .fixtureMissing(let name):
			"fixture \(name) isn't in the lab cache: run scripts/lab/fetch.sh fetch \(name)"
		case .specInvalid(let text):
			text
		case .guestCap(let running):
			"the lab already runs \(running) guests (at most 2)"
		case .stateTimeout(let vm, let wanted, let last):
			"\(vm) never reached \(wanted) (last \(last))"
		case .consoleUnavailable(let text):
			text
		case .consoleClosed(let tail):
			"the console closed; last output:\n\(tail)"
		case .expectTimeout(let pattern, let tail):
			"no /\(pattern)/ on the console in time; last output:\n\(tail)"
		case .logTimeout(let pattern):
			"no /\(pattern)/ in the lab log in time"
		case .commandFailed(let command, let status, let output):
			"\(command) exited \(status):\n\(output)"
		case .controlFailed(let text):
			text
		}
	}
}
