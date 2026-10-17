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

	// Debian outdated as above, its last Guest Setup run failed with a note and a feature
	// this guest can't do: every disclosure of the Guest Setup inspector has something in it.
	public static func libraryWithOutdatedSetupReport() -> [VMInfo] {
		library().map { vm in
			guard vm.name == "Debian" else { return vm }
			var debian = failedSetupRun("Debian")
			debian.outdatedHost = true
			debian.setup?.notes = setupNotes("Debian").setup?.notes
			debian.setup?.features = [
				GuestFeatureInfo(
					id: GuestFeature.ssh, available: true, configured: true, detail: "demo"),
				GuestFeatureInfo(
					id: GuestFeature.kernelConsole, available: false,
					reason: "no known bootloader tool on this guest", configured: false),
			]
			return debian
		}
	}
}
