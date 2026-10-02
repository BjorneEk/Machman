//
//  Samples+Wording.swift
//  MachmanFixtures
//
//  Lane 4a's samples (inspector and guide text): the mount cases the mount guide covers.
//

import Foundation
import MachmanAPI

extension Samples {
	public static let srcMountID = "7B0E4F52-3C1A-4D55-9E0B-2A6C1D9F0A11"

	// The library's Linux guest with its source mount not automounted (no setup report
	// automount yet), so the guest path is where the offered commands put it.
	public static func linuxManualMount(_ name: String = "Alpine") -> VMInfo {
		var vm = linux(name)
		vm.mounts = vm.mounts.map { mount in
			var mount = mount
			mount.automounted = nil
			mount.automountedAt = nil
			return mount
		}
		return vm
	}

	// A macOS guest sharing the same source folder (it automounts in the guest).
	public static func macOSWithMount(_ name: String = "Sequoia") -> VMInfo {
		var vm = macOS(name)
		vm.mounts = [MountInfo(id: srcMountID, path: "/Users/demo/src", tag: "src")]
		return vm
	}
}
