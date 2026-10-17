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
	// Deleted here: its vm.delete went through, so its port profiles go with it.
	@Test("T29: a deleted VM's port profiles don't pass to a new VM of that name")
	func aDeletedVMsProfilesAreForgotten() async throws {
		let h = await DesktopHarness.make()
		let ref = SerialPortRef(kind: .console, index: 0)
		let custom = h.profiles.addProfile()
		h.profiles.associate(vm: "Alpine", ref: ref, to: custom.id)
		#expect(h.profiles.associatedID(vm: "Alpine", ref: ref) == custom.id)
		let alpine = try #require(h.viewModel.vms.first { $0.name == "Alpine" })
		h.viewModel.performDeleteVM(alpine)
		#expect(await eventually { !h.viewModel.vms.contains { $0.name == "Alpine" } })
		#expect(h.profiles.associatedID(vm: "Alpine", ref: ref) == h.profiles.defaultProfile.id)
	}

	// Deleted elsewhere (another client, or while the app was away) and its name taken again:
	// the new VM's created date tells it from the old one, which keeps its profiles to itself.
	@Test("T29: a new VM under a deleted one's name gets none of its port profiles")
	func aNewVMUnderAnOldNameStartsOnTheDefault() async throws {
		let h = await DesktopHarness.make()
		let ref = SerialPortRef(kind: .console, index: 0)
		let custom = h.profiles.addProfile()
		h.profiles.associate(vm: "Alpine", ref: ref, to: custom.id)
		await h.store.reload()   // a list shows the VM the choice belongs to
		var reborn = try #require(h.stub.vms["Alpine"])
		reborn.created = reborn.created.addingTimeInterval(86_400)
		h.stub.vms["Alpine"] = reborn
		h.stub.emit(.listChanged)
		#expect(await eventually {
			h.profiles.associatedID(vm: "Alpine", ref: ref) == h.profiles.defaultProfile.id
		})
	}

	// A VM missing from one list hasn't gone: an external library that slept, a config that
	// briefly failed to load. Its port profiles wait for it.
	@Test("T29: a VM missing from one list keeps its port profiles when it comes back")
	func aVMMissingFromOneListKeepsItsProfiles() async throws {
		let h = await DesktopHarness.make()
		let ref = SerialPortRef(kind: .console, index: 0)
		let custom = h.profiles.addProfile()
		h.profiles.associate(vm: "Alpine", ref: ref, to: custom.id)
		await h.store.reload()
		let alpine = try #require(h.stub.vms["Alpine"])
		h.stub.vms["Alpine"] = nil
		await h.store.reload()
		#expect(!h.viewModel.vms.contains { $0.name == "Alpine" })
		#expect(h.profiles.associatedID(vm: "Alpine", ref: ref) == custom.id)
		h.stub.vms["Alpine"] = alpine
		await h.store.reload()
		#expect(h.viewModel.vms.contains { $0.name == "Alpine" })
		#expect(h.profiles.associatedID(vm: "Alpine", ref: ref) == custom.id)
	}

	// The name field's rename takes the port profiles along through the VM-keyed state; no
	// view hands the profile store in any more.
	@Test("T29: a VM renamed from its name field keeps its port profiles")
	func aRenameKeepsThePortProfiles() async throws {
		let h = await DesktopHarness.make()
		let ref = SerialPortRef(kind: .console, index: 0)
		let custom = h.profiles.addProfile()
		h.profiles.associate(vm: "Alpine", ref: ref, to: custom.id)
		let alpine = try #require(h.viewModel.vms.first { $0.name == "Alpine" })
		#expect(h.viewModel.submitRename(alpine, draft: "Alpine 2"))
		#expect(await eventually { h.viewModel.hasVM("Alpine 2") })
		#expect(h.profiles.associatedID(vm: "Alpine 2", ref: ref) == custom.id)
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

	// A port set back to the default holds no state, so its VM's recorded date goes with it:
	// a date kept for nothing would make the name pairable as a rename forever (T34).
	@Test("T34: a name whose last port profile went back to the default records no date")
	func aResetProfileLeavesNoDate() async throws {
		let h = await DesktopHarness.make()
		let ref = SerialPortRef(kind: .console, index: 0)
		let custom = h.profiles.addProfile()
		h.profiles.associate(vm: "Alpine", ref: ref, to: custom.id)
		await h.store.reload()
		#expect(h.profiles.ownerDates["Alpine"] != nil)
		h.profiles.associate(vm: "Alpine", ref: ref, to: h.profiles.defaultProfile.id)
		await h.store.reload()
		#expect(h.profiles.ownerDates["Alpine"] == nil)
	}
}
