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

	// A running Linux guest named with an apostrophe, with no ~/.ssh entry: its SSH inspector
	// shows the self-contained ssh line, whose key path carries the name (C26).
	public static func linuxApostropheName(_ name: String = "Bob's Ubuntu") -> VMInfo {
		var vm = linux(name, state: .running)
		vm.ssh?.alias = SSHAliasRule.defaultAlias(for: name)
		vm.ssh?.integrationEnabled = false
		vm.ssh?.identityFilePath = "\(vmsRoot)/\(name)/ssh/id_ed25519"
		return vm
	}

	// A Linux guest in a safe run — what Save as New VM is offered for.
	public static func linuxSafeRun(_ name: String = "Debian") -> VMInfo {
		var vm = linux(name, state: .running)
		vm.safeRun = true
		return vm
	}
}
