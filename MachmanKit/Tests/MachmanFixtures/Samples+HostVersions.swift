//
//  Samples+HostVersions.swift
//  MachmanFixtures
//
//  A VM still run by a vmhost older than the daemon (E22), as the daemon serves it: marked
//  outdatedHost, its settings locked until it restarts.
//

import Foundation
import MachmanAPI

extension Samples {
	// A running Linux VM whose vmhost outlived an update of the app.
	public static func outdatedHost(_ name: String = "Debian") -> VMInfo {
		var vm = linux(name, state: .running)
		vm.outdatedHost = true
		return vm
	}

	// The sample library with Debian's vmhost outdated; every other VM as library() has it.
	public static func libraryWithOutdatedHost() -> [VMInfo] {
		library().map { $0.name == "Debian" ? outdatedHost("Debian") : $0 }
	}
}
