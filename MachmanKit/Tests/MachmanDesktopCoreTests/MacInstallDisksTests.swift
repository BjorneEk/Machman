//
//  MacInstallDisksTests.swift
//  MachmanDesktopCoreTests
//
//  D32 (K4): Bootloader ▸ macOS… on a VM that has disks installed over one of them without a
//  word. The switch sheet now asks: a new disk, preselected, or one of the VM's own writable
//  disks by name — what that erases said once it is picked, and a disk smaller than a new one
//  carrying a warning rather than a refusal (K15). A retry asks nothing.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct MacInstallDisksTests {
	@Test("D32: the macOS switch offers each writable disk, and nothing on a retry")
	func theSwitchOffersTheWritableDisks() {
		let vm = Samples.linuxBeforeMacSwitch()
		let offered = MacInstallDisks.offered(for: vm)
		#expect(offered.map(\.type) == [.storage, .storage, .image])
		#expect(offered.map(MacInstallDisks.title)
			== ["system (80 GB)", "data (8 GB)", "ubuntu-24.04-arm64.img (20 GB)"])
		#expect(MacInstallDisks.newDiskTitle == "A new disk (64 GB)")
		#expect(offered.map { MacInstallDisks.sizeWarning($0) != nil } == [false, true, true])
		#expect(MacInstallDisks.notes(offered[0])
			== ["Installing erases \u{201C}system\u{201D} and can\u{2019}t be undone."])
		#expect(MacInstallDisks.notes(offered[1]) == [
			"Installing erases \u{201C}data\u{201D} and can\u{2019}t be undone.",
			"macOS may not fit on a disk under 64 GB.",
		])
		#expect(MacInstallDisks.offered(for: Samples.macOSFailedInstall()).isEmpty)
		var bare = Samples.linux("Bare")
		bare.disks.removeAll { $0.type != .iso }
		#expect(MacInstallDisks.offered(for: bare).isEmpty)
	}

	@Test("D32: a picked disk goes out with the install, and the default sends none")
	func thePickTravelsWithTheInstall() async throws {
		let h = await DesktopHarness.make([Samples.linuxBeforeMacSwitch()])
		h.viewModel.startInstall("Alpine", source: .latest)
		#expect(await eventually { h.stub.installs.count == 1 })
		h.viewModel.startInstall("Alpine", source: .ipsw("/x.ipsw"), diskID: "storage:data")
		#expect(await eventually { h.stub.installs.count == 2 })
		#expect(h.stub.installs.map(\.diskID) == [nil, "storage:data"])
		#expect(h.stub.installs.last?.source == .ipsw("/x.ipsw"))
	}
}
