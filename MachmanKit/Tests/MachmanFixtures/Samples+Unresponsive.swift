//
//  Samples+Unresponsive.swift
//  MachmanFixtures
//
//  A VM whose vmhost stopped answering (E20), as the daemon serves it: its last answer,
//  marked unresponsive. And one whose vmhost Machman Agent hasn't reached yet: state unknown.
//

import Foundation
import MachmanAPI

extension Samples {
	// A running Linux VM whose vmhost misses its answer deadline.
	public static func notResponding(_ name: String = "Debian") -> VMInfo {
		var vm = linux(name, state: .running)
		vm.unresponsive = true
		return vm
	}

	// The sample library with Debian's vmhost stalled; every other VM as library() has it.
	public static func libraryWithStalledHost() -> [VMInfo] {
		library().map { $0.name == "Debian" ? notResponding("Debian") : $0 }
	}

	// A running Linux VM whose vmhost the agent hasn't adopted yet (after the agent restarted,
	// or a launch-agent start): the daemon's config copy, state unknown.
	public static func unreached(_ name: String = "Debian") -> VMInfo {
		linux(name, state: .unknown)
	}

	// The sample library with Debian's vmhost not reached yet.
	public static func libraryWithUnreachedHost() -> [VMInfo] {
		library().map { $0.name == "Debian" ? unreached("Debian") : $0 }
	}

	// The sample library with Debian's vmhost never answering (an adoption that failed).
	public static func libraryWithNeverAnsweredHost() -> [VMInfo] {
		library().map { $0.name == "Debian" ? neverAnswered("Debian") : $0 }
	}
}
