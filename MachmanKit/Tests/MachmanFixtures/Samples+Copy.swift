//
//  Samples+Copy.swift
//  MachmanFixtures
//
//  Lane 2d's samples (copy, disks, install): what Duplicate… is offered for.
//

import Foundation
import MachmanAPI

extension Samples {
	// The copy of a Mac whose install never finished (C10): it needs installing, and says
	// why in the engine's words (VMCopier.unfinishedInstallNote).
	public static func macOSUnfinishedCopy(_ name: String = "Sequoia copy") -> VMInfo {
		var vm = macOS(name)
		vm.boot.macInstallState = MacInstallState(
			kind: .failed,
			message: "Duplicated before macOS was installed")
		return vm
	}
}
