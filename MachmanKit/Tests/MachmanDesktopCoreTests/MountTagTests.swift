//
//  MountTagTests.swift
//  MachmanDesktopCoreTests
//
//  Every drop, paste and folder pick names the mount after the folder. A hidden folder
//  (.config) can't be a mount tag any more, so it mounts under a cleaned tag the user can
//  rename instead of being refused.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct MountTagTests {
	@Test func aHiddenFolderMountsUnderACleanTag() async {
		let h = await DesktopHarness.make()
		h.viewModel.addMount("Debian", path: "/Users/demo/.config", tag: ".config")
		#expect(await eventually {
			h.stub.vms["Debian"]?.mounts.contains { $0.tag == "config" } == true
		})
		h.viewModel.addMount("Debian", path: "/Users/demo/a:b", tag: "a:b")
		#expect(await eventually {
			h.stub.vms["Debian"]?.mounts.contains { $0.tag == "a-b" } == true
		})
		h.viewModel.addMount("Debian", path: "/Users/demo/src2", tag: "src2")
		#expect(await eventually {
			h.stub.vms["Debian"]?.mounts.contains { $0.tag == "src2" } == true
		})
	}
}
