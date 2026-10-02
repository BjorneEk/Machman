//
//  GuestSetupCommands+Guides.swift
//  MachmanDesktopCore
//
//  Where a host folder lands in the guest (X5), next to the other copyable guest commands so
//  the inspectors and the guides cannot disagree.
//

import Foundation
import MachmanAPI

extension GuestSetupCommands {
	// Where `mount` shows up in the guest: the reported automount first, else where the
	// commands Machman offers put it — sshfs folders under the mounts root, virtiofs ones as
	// tag subdirectories of the share (macOS: of its automounted volume).
	public static func guestPath(of mount: MountInfo, on vm: VMInfo) -> String {
		if let reported = mount.automountedAt { return reported }
		if mount.effectiveKind == MountKind.sshfs {
			return GuestPaths.sshfsMountPoint(name: mount.tag)
		}
		let root = vm.boot.mode == .macOS ? GuestPaths.macOSAutomount : GuestPaths.share
		return root + "/" + mount.tag
	}
}
