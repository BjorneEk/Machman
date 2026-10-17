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
		#expect(h.profiles.associatedID(vm: "Alpine", ref: ref) == h.profiles.defaultProfile.id)
	}

	// Save as New VM moved the run's console to the saved name but left its profile behind:
	// the inspector showed Default, and the next edit of the default profile restyled it.
	@Test("T29: Save as New VM keeps the moved console on its custom profile")
	func aSafeSaveTakesThePortProfilesAlong() async throws {
		let h = await DesktopHarness.make([Samples.linuxSafeRun("Debian")])
		h.stub.safeSaveKeepsOriginal = true
		h.terminals.follow(h.profiles)
		let ref = SerialPortRef(kind: .console, index: 0)
		let custom = h.profiles.addProfile()
		h.profiles.associate(vm: "Debian", ref: ref, to: custom.id)
		let socket = try #require(h.viewModel.vms.first?.consolePorts?.first?.socketPath)
		h.terminals.ensureController(
			vm: "Debian", ref: ref, socketPath: socket,
			profile: h.profiles.profile(vm: "Debian", ref: ref))
		#expect(await eventually { h.terminals.controller(vm: "Debian", ref: ref) != nil })
		let console = try #require(
			h.terminals.controller(vm: "Debian", ref: ref) as? FakeTerminalController)

		h.viewModel.safeSave("Debian", to: "Debian kept")
		#expect(await eventually { h.viewModel.selectedName == "Debian kept" })
		#expect(h.terminals.controller(vm: "Debian kept", ref: ref) === console)
		#expect(h.profiles.associatedID(vm: "Debian kept", ref: ref) == custom.id)
		#expect(h.profiles.associatedID(vm: "Debian", ref: ref) == custom.id)   // the original's

		var edited = h.profiles.defaultProfile
		edited.fontSize += 2
		h.profiles.update(edited)
		#expect(await settled { console.liveApplies })
		#expect(console.liveApplies == 0)
	}
}
