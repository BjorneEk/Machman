//
//  ExternalRenameTests.swift
//  MachmanDesktopCoreTests
//
//  A VM renamed somewhere else — another desktop, a script over the socket, Finder while the
//  agent was away (T34). Client state moved only on renames this desktop asked for, so such a
//  rename looked like one VM leaving and another arriving: the layout and the port profiles
//  stayed under the old name. The created date tells it is the same VM.
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
struct ExternalRenameTests {
	private static let ref = SerialPortRef(kind: .console, index: 0)

	// The samples share one created date; real VMs each have their own.
	private static func library() -> [VMInfo] {
		Samples.library().enumerated().map { offset, vm in
			var vm = vm
			vm.created = vm.created.addingTimeInterval(Double(offset) * 86_400)
			return vm
		}
	}

	@Test("T34: a VM renamed elsewhere keeps its canvas layout and port profiles")
	func anExternalRenameMovesTheState() async throws {
		let h = await DesktopHarness.make(Self.library())
		h.open(.terminal(Self.ref), vm: "Alpine")
		let custom = h.profiles.addProfile()
		h.profiles.associate(vm: "Alpine", ref: Self.ref, to: custom.id)
		await h.store.reload()   // a list shows the VM the state belongs to
		let removed = h.stub.vms.removeValue(forKey: "Alpine")
		var renamed = try #require(removed)
		renamed.name = "Bookworm"
		h.stub.vms["Bookworm"] = renamed
		await h.store.reload()
		#expect(h.canvases.canvas(for: "Bookworm").allOpenTabs.contains(.terminal(Self.ref)))
		#expect(h.canvases.canvases["Alpine"] == nil)
		#expect(h.profiles.associatedID(vm: "Bookworm", ref: Self.ref) == custom.id)
		#expect(h.profiles.associatedID(vm: "Alpine", ref: Self.ref)
			== h.profiles.defaultProfile.id)
	}

	// Renamed while the desktop was closed: the first list after launch shows only the new
	// name, and the saved layout's recorded date still finds it.
	@Test("T34: a layout saved under a VM's old name follows it to the name the first list shows")
	func aRenameWhileAwayIsFound() throws {
		let url = TestEnvironment.scratchURL.appendingPathComponent(UUID().uuidString)
			.appendingPathComponent("Canvas.json")
		let alpine = try #require(Samples.library().first { $0.name == "Alpine" })
		let before = CanvasStateStore(fileURL: url, saveDelay: .zero)
		var canvas = CanvasState()
		canvas.open(.terminal(Self.ref))
		before.setCanvas(canvas, for: "Alpine")
		before.listed([alpine])
		before.flush()
		var renamed = alpine
		renamed.name = "Bookworm"
		let after = CanvasStateStore(fileURL: url, saveDelay: .zero)
		after.listed([renamed])
		#expect(after.canvases["Bookworm"] == canvas)
		#expect(after.canvases["Alpine"] == nil)
	}

	// A different VM arriving while another is away is no rename.
	@Test("T34: a new VM arriving while another is away takes none of its state")
	func aNewVMIsNoRename() async throws {
		let h = await DesktopHarness.make(Self.library())
		h.open(.terminal(Self.ref), vm: "Alpine")
		await h.store.reload()
		let removed = h.stub.vms.removeValue(forKey: "Alpine")
		var other = try #require(removed)
		other.name = "Bookworm"
		other.created = other.created.addingTimeInterval(86_400)
		h.stub.vms["Bookworm"] = other
		await h.store.reload()
		#expect(h.canvases.canvases["Bookworm"] == nil)
		#expect(h.canvases.canvases["Alpine"] != nil)
	}

	// A date two listed VMs share (a folder duplicated in Finder keeps its config) moves
	// nothing: either could be the one renamed.
	@Test("T34: a date two listed VMs share moves no state")
	func aSharedDateIsNoRename() async throws {
		let h = await DesktopHarness.make(Self.library())
		h.open(.terminal(Self.ref), vm: "Alpine")
		await h.store.reload()
		let removed = h.stub.vms.removeValue(forKey: "Alpine")
		let alpine = try #require(removed)
		for name in ["Bookworm", "Bookworm copy"] {
			var twin = alpine
			twin.name = name
			h.stub.vms[name] = twin
		}
		await h.store.reload()
		#expect(h.canvases.canvases["Bookworm"] == nil)
		#expect(h.canvases.canvases["Bookworm copy"] == nil)
		#expect(h.canvases.canvases["Alpine"] != nil)
	}
}
