//
//  Samples+Inspectors.swift
//  MachmanFixtures
//
//  Lane 3c's samples (inspectors, sheets, units): the states the inspectors and the
//  Duplicate sheet show that the base samples don't reach.
//

import Foundation
import MachmanAPI

extension Samples {
	// A Linux guest whose system disk is 500 MB — under one GB, which a whole-GB figure
	// truncated to zero.
	public static func linuxSmallDisk(_ name: String = "Alpine") -> VMInfo {
		var vm = linux(name)
		vm.disks[0].sizeBytes = 500 << 20
		return vm
	}
}
