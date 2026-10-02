//
//  GuideCommandTests.swift
//  MachmanDesktopCoreTests
//
//  X4: the Rosetta inspector's copy button copied an English sentence ("…must be registered
//  with binfmt_misc (see Apple's … docs)") after a mount with no mkdir and no root. X5: the
//  mount inspector named a mount's guest folder only in prose, and its macOS copy button
//  copied a path. The guides and the inspector now take both from GuestSetupCommands.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
@testable import MachmanDesktopCore

struct GuideCommandTests {
	@Test func rosettaMountsWithMkdirAndRoot() {
		#expect(GuestSetupCommands.rosettaMount()
			== "sudo mkdir -p /media/rosetta && sudo mount -t virtiofs rosetta /media/rosetta")
		#expect(GuestSetupCommands.rosettaMount(.root)
			== "mkdir -p /media/rosetta && mount -t virtiofs rosetta /media/rosetta")
	}

	// Apple's update-binfmts magic and mask, credentials + fix-binary, written with printf %s
	// so no shell turns the escapes into bytes; nothing in it is prose.
	@Test func rosettaRegistersThroughBinfmtMisc() {
		let rule = ":rosetta:M::"
			+ #"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00"#
			+ ":"
			+ #"\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff"#
			+ ":/media/rosetta/rosetta:CF"
		#expect(GuestSetupCommands.rosettaRegister()
			== "printf '%s\\n' '\(rule)' | sudo tee /proc/sys/fs/binfmt_misc/register")
		#expect(GuestSetupCommands.rosettaRegister(.root)
			== "printf '%s\\n' '\(rule)' | tee /proc/sys/fs/binfmt_misc/register")
	}

	// R4-4: OpenRC and runit guests may not have binfmt_misc mounted, so the register line
	// above fails there; the guide offers the mount.
	@Test func binfmtMiscMountsWhereTheGuestDidNot() {
		#expect(GuestSetupCommands.binfmtMiscMount()
			== "sudo mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc")
		#expect(GuestSetupCommands.binfmtMiscMount(.doas)
			== "doas mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc")
		#expect(GuestSetupCommands.binfmtMiscMount(.root)
			== "mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc")
	}

	// R4-3: the guides showed two macOS 12 mounts, and the Guest Setup one made the folder in
	// the user's home as root. One line now: the mkdir the user's, the mount (and the
	// installer run from it) escalated.
	@Test func macOS12MountsTheSameWayInBothGuides() {
		let mount = GuestSetupCommands.macOS12MountShare()
		#expect(mount == "mkdir -p ~/shared && "
			+ "sudo mount_virtiofs com.apple.virtio-fs.automount ~/shared")
		#expect(GuestSetupCommands.macOS12MountShareAndRun()
			== mount + " && sudo sh ~/shared/GuestSetup/install.sh")
		#expect(GuestSetupCommands.macOS12MountShareAndRun(.root)
			== "mkdir -p ~/shared && mount_virtiofs com.apple.virtio-fs.automount ~/shared "
				+ "&& sh ~/shared/GuestSetup/install.sh")
	}

	@Test func aMountsGuestPathFollowsItsKindAndGuest() {
		let manual = Samples.linuxManualMount()
		#expect(GuestSetupCommands.guestPath(of: manual.mounts[0], on: manual)
			== "/mnt/machman/share/src")
		let mac = Samples.macOSWithMount()
		#expect(GuestSetupCommands.guestPath(of: mac.mounts[0], on: mac)
			== "/Volumes/My Shared Files/src")
		let mounts = Samples.linuxWithMounts()
		let notes = mounts.mounts.first { $0.id == Samples.notesMountID }!
		#expect(GuestSetupCommands.guestPath(of: notes, on: mounts) == "/mnt/machman/mounts/notes")
	}

	// What the guest's setup report says wins over where the commands would put it.
	@Test func aReportedAutomountWins() {
		let vm = Samples.linux()
		#expect(GuestSetupCommands.guestPath(of: vm.mounts[0], on: vm) == "/mnt/machman/src")
	}
}
