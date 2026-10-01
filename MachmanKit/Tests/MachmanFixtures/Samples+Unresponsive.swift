//
//  Samples+Unresponsive.swift
//  MachmanFixtures
//
//  A VM whose vmhost stopped answering (E20), as the daemon serves it: its last answer,
//  marked unresponsive.
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
}
