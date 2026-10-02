//
//  GuideCommandTests.swift
//  MachmanDesktopCoreTests
//
//  X5: the mount inspector named a mount's guest folder only in prose, and its macOS copy
//  button copied a path. The inspector's Guest path row and the mount guide now take it from
//  GuestSetupCommands.guestPath.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
@testable import MachmanDesktopCore

struct GuideCommandTests {
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
