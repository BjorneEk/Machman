//
//  GuestSetupGuideTests.swift
//  MachmanDesktopCoreTests
//
//  The Guest Setup guide's steps, read as GuestSetupGuide words them (Q21) without hosting
//  the sheet: the BSD bootstrap's step 5 says whether the Mac will ask for its password (only
//  until the guest's key is approved), and a guest whose share already automounts skips the
//  bootstrap.
//

import Testing
import MachmanAPI
import MachmanFixtures
@testable import MachmanDesktopCore

struct GuestSetupGuideTests {
	private static func step(_ number: Int, in lines: [GuestSetupGuide.Line]) -> String? {
		for case .step(number, let text) in lines { return text }
		return nil
	}

	@Test("Q21: the BSD guide's step 5 says whether the Mac asks for a password")
	func theBSDStepFiveFollowsTheApproval() throws {
		let plain = GuestSetupGuide.bsd(Samples.linux("Debian"))
		#expect(Self.step(5, in: plain)
			== "Mount Machman’s setup folder (it asks for your Mac password once):")
		#expect(Self.step(6, in: plain) == "Run the installer:")

		let approved = GuestSetupGuide.bsd(Samples.linuxReverseApproved())
		#expect(Self.step(5, in: approved)
			== "Mount Machman’s setup folder — the approved key needs no password:")

		// The share automounts already: three steps, no bootstrap.
		var mounted = Samples.linux("Debian")
		mounted.setup?.automounts = [GuestAutomountInfo(
			kind: MountKind.virtiofs, target: "@share", path: "/mnt/machman")]
		let short = GuestSetupGuide.bsd(mounted)
		#expect(Self.step(1, in: short) == "Start the VM — the share appears at /mnt/machman.")
		#expect(Self.step(4, in: short) == nil)
		#expect(Self.step(2, in: GuestSetupGuide.linux(mounted))
			== "The share automounts (virtiofs) at /mnt/machman — run the script:")
	}
}
