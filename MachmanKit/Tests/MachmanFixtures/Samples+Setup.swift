//
//  Samples+Setup.swift
//  MachmanFixtures
//
//  A guest whose last setup report came from an older script than the app ships, still
//  pinned to it (S67): an app update never moves a VM's script.
//

import Foundation
import MachmanAPI

extension Samples {
	// A running Linux VM set up by the store's v2 and pinned to it, while the latest is v3:
	// Installed and Serves read v2, the menu marks v3 the latest.
	public static func olderSetupScript(_ name: String = "Debian") -> VMInfo {
		var vm = linux(name, state: .running)
		vm.setup?.scriptVersion = 2
		vm.setup?.installedScript = setupScriptOlder.id
		vm.setup?.servedScript = setupScriptOlder.id
		return vm
	}
}
