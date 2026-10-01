//
//  Samples+Setup.swift
//  MachmanFixtures
//
//  A guest whose last setup report came from an older script than the app ships.
//

import Foundation
import MachmanAPI

extension Samples {
	// A running Linux VM that ran setup script v3 while the app ships v4: the Guest Setup
	// inspector offers the re-run.
	public static func olderSetupScript(_ name: String = "Debian") -> VMInfo {
		var vm = linux(name, state: .running)
		vm.setup?.scriptVersion = 3
		vm.setup?.currentScriptVersion = 4
		return vm
	}
}
