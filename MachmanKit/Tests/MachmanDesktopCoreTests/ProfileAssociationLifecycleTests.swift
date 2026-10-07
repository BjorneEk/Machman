//
//  ProfileAssociationLifecycleTests.swift
//  MachmanDesktopCoreTests
//
//  Per-port terminal profiles ("vm|kind|index" associations) against the VM's lifecycle
//  (T29): a rename moves them, but a deleted VM's stayed, so a new VM created under the
//  same name inherited the old one's per-port profiles.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// L1: view model on StubMachman.
@MainActor
struct ProfileAssociationLifecycleTests {
	@Test("T29: a deleted VM's port profiles don't pass to a new VM of that name")
	func aDeletedVMsProfilesAreForgotten() async throws {
		let h = await DesktopHarness.make()
		let ref = SerialPortRef(kind: .console, index: 0)
		let custom = h.profiles.addProfile()
		h.profiles.associate(vm: "Alpine", ref: ref, to: custom.id)
		#expect(h.profiles.associatedID(vm: "Alpine", ref: ref) == custom.id)
		h.stub.vms["Alpine"] = nil
		h.stub.emit(.listChanged)
		#expect(await eventually { !h.viewModel.vms.contains { $0.name == "Alpine" } })
		// Fails until the open bug T29 (port profiles outlive their VM) is fixed.
		#expect(h.profiles.associatedID(vm: "Alpine", ref: ref) == h.profiles.defaultProfile.id)
	}
}
