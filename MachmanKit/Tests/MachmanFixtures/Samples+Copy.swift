//
//  Samples+Copy.swift
//  MachmanFixtures
//
//  Lane 2d's samples (copy, disks, install): what Duplicate… is offered for.
//

import Foundation
import MachmanAPI

extension Samples {
	// The id of linuxWithMounts' second mount (the sshfs one).
	public static let notesMountID = "3F9A2C10-8B7D-4E21-A5C3-6D0E1F2B3C44"

	// A Linux guest with two mounts — its virtiofs source tree and an sshfs notes folder deep
	// in iCloud Drive (a path long enough to truncate) — for Duplicate…'s mount choice.
	public static func linuxWithMounts(_ name: String = "Debian") -> VMInfo {
		var vm = linux(name)
		vm.mounts.append(MountInfo(
			id: notesMountID,
			path: "/Users/demo/Library/Mobile Documents/com~apple~CloudDocs/Notes/2026",
			tag: "notes", kind: MountKind.sshfs))
		return vm
	}

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
