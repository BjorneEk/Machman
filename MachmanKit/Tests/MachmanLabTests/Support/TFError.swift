//
//  TFError.swift
//  MachmanLabTests
//
//  What r3-tf's engine helpers throw; each description names what to do next.
//

import Foundation

enum TFError: Error, CustomStringConvertible {
	/// A bounded wait ran out: what was awaited.
	case timeout(String)
	/// A race the test set up was lost (the work finished first, the kill came late): what to
	/// resize or retry.
	case inconclusive(String)
	/// The scene the test needs isn't there (a fixture, a process, a file).
	case precondition(String)

	var description: String {
		switch self {
		case .timeout(let what):
			"timed out waiting for \(what); the lab log and transcripts show the last state"
		case .inconclusive(let why):
			"inconclusive: \(why)"
		case .precondition(let what):
			"precondition: \(what)"
		}
	}
}
