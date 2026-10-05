//
//  GuestSetupCommands+Guides.swift
//  MachmanDesktopCore
//
//  Where a host folder lands in the guest (X5) and the Rosetta guest commands (X4), next
//  to the other copyable guest commands so the inspectors and the guides cannot disagree.
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

	// MARK: - Rosetta (Linux guests)

	// Apple's documented mount point for the Rosetta share; the tag is the engine's.
	public static let rosettaMountPoint = "/media/rosetta"

	public static func rosettaMount(_ escalation: GuestEscalation = .sudo) -> String {
		escalation.apply(GuestCommand("mkdir -p \(rosettaMountPoint)")
			.and("mount -t virtiofs rosetta \(rosettaMountPoint)"))
	}

	// Registers Rosetta for x86-64 ELF binaries straight through binfmt_misc: Apple's
	// update-binfmts magic and mask with its credentials and fix-binary flags (C, F), so no
	// distro package is needed. printf '%s' hands the \x escapes over literally in every
	// shell (zsh's and macOS sh's echo would turn them into bytes). Lasts until the guest
	// restarts.
	public static func rosettaRegister(_ escalation: GuestEscalation = .sudo) -> String {
		"printf '%s\\n' '\(rosettaBinfmtRule)' | \(escalation.prefix)tee "
			+ "\(binfmtMiscDirectory)/register"
	}

	// systemd mounts binfmt_misc on its own; under OpenRC or runit (Alpine, Void) it may not
	// be, and the register line then fails with "No such file or directory".
	public static func binfmtMiscMount(_ escalation: GuestEscalation = .sudo) -> String {
		escalation.apply(GuestCommand("mount -t binfmt_misc binfmt_misc \(binfmtMiscDirectory)"))
	}

	static let binfmtMiscDirectory = "/proc/sys/fs/binfmt_misc"

	static let rosettaBinfmtRule = ":rosetta:M::"
		+ #"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00"#
		+ ":"
		+ #"\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff"#
		+ ":\(rosettaMountPoint)/rosetta:CF"
}
