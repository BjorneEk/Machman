//
//  GuestSetupCommandTests.swift
//  MachmanDesktopCoreTests
//
//  H12: the Guest Setup inspector's copyable run line had no root prefix where the share
//  automounts and on BSD, so it stopped at once for a normal user ("this script has to run
//  as root"), and the mount inspector's Linux mount line had none either (H29). H13: the
//  guide's BSD mount step was hard-coded with doas and escalated again ("doas doas", "sudo
//  doas"); its fuse step left the kldload after "||" unescalated (H28); and its BSD tab
//  opened on sudo, which neither BSD ships (H30). Every surface now takes its commands from
//  GuestSetupCommands, unescalated, and escalates them once.
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
			== "sudo mkdir -p /mnt/machman/share && sudo mount -t virtiofs host-share "
				+ "/mnt/machman/share && sudo " + script)
		#expect(GuestSetupCommands.run(.bsd, shareMounted: true) == "doas " + script)
		#expect(GuestSetupCommands.run(.macOS, shareMounted: true)
			== "sudo sh \"/Volumes/My Shared Files/GuestSetup/install.sh\"")
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

	private func shareMount(approved: Bool) -> String {
		GuestSetupCommands.bsdShareMount(
			approvedGuestUser: approved ? "demo" : nil, hostUser: "demo",
			hostAddress: "192.168.64.1", sharePath: "/Users/demo/VMs/Debian/share")
	}

	private func count(_ needle: String, in text: String) -> Int {
		text.components(separatedBy: needle).count - 1
	}

	@Test func theBSDMountIsEscalatedExactlyOnce() {
		for approved in [true, false] {
			let doas = GuestEscalation.doas.apply(shareMount(approved: approved))
			#expect(count("doas ", in: doas) == 2)
			#expect(!doas.contains("doas doas"))
			let sudo = GuestEscalation.sudo.apply(shareMount(approved: approved))
			#expect(count("sudo ", in: sudo) == 2)
			#expect(!sudo.contains("doas"))
			let root = GuestEscalation.root.apply(shareMount(approved: approved))
			#expect(!root.contains("sudo") && !root.contains("doas"))
		}
		#expect(GuestEscalation.doas.apply(shareMount(approved: true))
			== "doas mkdir -p /mnt/machman/share && doas sshfs -F /home/demo/.ssh/config "
				+ "mac:'/Users/demo/VMs/Debian/share' /mnt/machman/share "
				+ "-o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3")
	}

	@Test func theFuseFallbackRunsAsRootToo() {
		#expect(GuestEscalation.doas.apply(GuestSetupCommands.bsdFuseLoad)
			== "doas kldstat -q -m fusefs || doas kldload fusefs")
	}

	@Test func theBSDTabLeadsWithDoas() {
		#expect(GuestSetupCommands.escalations(for: .bsd).first == .doas)
		#expect(GuestSetupCommands.escalations(for: .linux).first == .sudo)
		#expect(!GuestSetupCommands.escalations(for: .macOS).contains(.doas))
	}
}
