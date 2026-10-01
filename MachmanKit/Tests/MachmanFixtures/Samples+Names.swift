//
//  Samples+Names.swift
//  MachmanFixtures
//
//  Lane 1a's samples (names and validation): VMs whose names exercise the name rules.
//

import Foundation
import MachmanAPI

extension Samples {
	// A Linux guest named with a space — what every Duplicate creates ("Debian copy") — served
	// with the alias the daemon maps that name to.
	public static func linuxSpacedName(_ name: String = "Debian copy") -> VMInfo {
		var vm = linux(name)
		vm.ssh?.alias = SSHAliasRule.defaultAlias(for: name)
		return vm
	}
}
