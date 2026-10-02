//
//  GuestSetupCommandTests.swift
//  MachmanDesktopCoreTests
//
//  H12: the Guest Setup inspector's copyable run line had no root prefix where the share
//  automounts and on BSD, so it stopped at once for a normal user ("this script has to run
//  as root"), and the mount inspector's Linux mount line had none either (H29). Every
//  surface now takes its commands from GuestSetupCommands.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanDesktopCore

struct GuestSetupCommandTests {
	private let script = "sh /mnt/machman/share/GuestSetup/install.sh"

	@Test func theRunLineCarriesTheFamilysEscalation() {
		#expect(GuestSetupCommands.run(.linux, shareMounted: true) == "sudo " + script)
		#expect(GuestSetupCommands.run(.linux, shareMounted: false)
			== GuestSetupInstallerInfo.mountAndRunCommand)
		#expect(GuestSetupCommands.run(.bsd, shareMounted: true) == "doas " + script)
		#expect(GuestSetupCommands.run(.macOS, shareMounted: true)
			== GuestSetupInstallerInfo.runCommand)
	}

	@Test func mountingTheShareRunsEveryCommandAsRoot() {
		#expect(GuestSetupCommands.mountShare(.linux)
			== "sudo mkdir -p /mnt/machman/share && sudo mount -t virtiofs host-share "
				+ "/mnt/machman/share")
	}

	@Test func rootChangesNothing() {
		let chain = "mkdir -p /x && mount /x || true"
		#expect(GuestEscalation.root.apply(chain) == chain)
		#expect(GuestEscalation.sudo.apply(chain)
			== "sudo mkdir -p /x && sudo mount /x || sudo true")
	}
}
