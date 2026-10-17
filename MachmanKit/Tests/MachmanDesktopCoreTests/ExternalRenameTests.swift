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
import Combine
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// L1: view model on StubMachman.
@MainActor
struct ExternalRenameTests {
	private static let ref = SerialPortRef(kind: .console, index: 0)
	private static let console = VMPaneTab.terminal(ref)

	// The samples share one created date; real VMs each have their own.
	private static func library() -> [VMInfo] {
		Samples.library().enumerated().map { offset, vm in
			var vm = vm
			vm.created = vm.created.addingTimeInterval(Double(offset) * 86_400)
			return vm
		}
	}

	// The agent now lists `old` as `new` (same VM, same created date).
	private static func rename(_ h: DesktopHarness, _ old: String, to new: String) throws {
		let removed = h.stub.vms.removeValue(forKey: old)
		var vm = try #require(removed)
		vm.name = new
		h.stub.vms[new] = vm
	}

	@Test("T34: a VM renamed elsewhere keeps its canvas layout and port profiles")
	func anExternalRenameMovesTheState() async throws {
		let h = await DesktopHarness.make(Self.library())
		h.open(Self.console, vm: "Alpine")
		let custom = h.profiles.addProfile()
		h.profiles.associate(vm: "Alpine", ref: Self.ref, to: custom.id)
		await h.store.reload()   // a list shows the VM the state belongs to
		try Self.rename(h, "Alpine", to: "Bookworm")
		await h.store.reload()
		#expect(h.canvases.canvas(for: "Bookworm").allOpenTabs.contains(Self.console))
		#expect(h.canvases.canvases["Alpine"] == nil)
		#expect(h.profiles.associatedID(vm: "Bookworm", ref: Self.ref) == custom.id)
		#expect(h.profiles.associatedID(vm: "Alpine", ref: Self.ref)
			== h.profiles.defaultProfile.id)
	}

	// Renamed while the desktop was closed: the connection's first list shows only the new
	// name, and the saved layout's recorded date still finds it.
	@Test("T34: a layout saved under a VM's old name follows it to the name the first list shows")
	func aRenameWhileAwayIsFound() async throws {
		let dir = TestEnvironment.scratchURL.appendingPathComponent(UUID().uuidString)
		let canvases = CanvasStateStore(fileURL: dir.appendingPathComponent("Canvas.json"))
		let library = Self.library()
		let alpine = try #require(library.first { $0.name == "Alpine" })
		var canvas = CanvasState()
		canvas.open(Self.console)
		canvases.setCanvas(canvas, for: "Alpine")
		canvases.listed([alpine])   // the last session recorded Alpine's date
		var renamed = alpine
		renamed.name = "Bookworm"
		let stub = StubMachman.serving(library.filter { $0.name != "Alpine" } + [renamed])
		let store = VMStore()
		store.attach(api: stub)
		let operations = OperationsStore()
		operations.attach(api: stub)
		let viewModel = VMListViewModel(
			api: stub, store: store, operations: operations,
			terminals: TerminalSessions { FakeTerminalController(profile: $0) },
			previews: PreviewService(store: store), canvases: canvases,
			tornTabs: TornTabRegistry())
		#expect(await eventually { canvases.canvases["Bookworm"] == canvas })
		#expect(canvases.canvases["Alpine"] == nil)
		_ = viewModel
	}

	// A different VM arriving while another is away is no rename.
	@Test("T34: a new VM arriving while another is away takes none of its state")
	func aNewVMIsNoRename() async throws {
		let h = await DesktopHarness.make(Self.library())
		h.open(Self.console, vm: "Alpine")
		await h.store.reload()
		try Self.rename(h, "Alpine", to: "Bookworm")
		h.stub.vms["Bookworm"]?.created.addTimeInterval(3_600)
		await h.store.reload()
		#expect(h.canvases.canvases["Bookworm"] == nil)
		#expect(h.canvases.canvases["Alpine"] != nil)
	}

	// A date two listed VMs share (a folder duplicated in Finder keeps its config) moves
	// nothing: either could be the one renamed.
	@Test("T34: a date two listed VMs share moves no state")
	func aSharedDateIsNoRename() async throws {
		let h = await DesktopHarness.make(Self.library())
		h.open(Self.console, vm: "Alpine")
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

	// This desktop's own rename moved the state; a list fetched before it still shows the
	// old name, which is no rename back (T16's promise).
	@Test("T34: a list from before this desktop's own rename moves nothing back")
	func aStaleListAfterOwnRenameMovesNothing() async throws {
		let h = await DesktopHarness.make(Self.library())
		h.open(Self.console, vm: "Alpine")
		await h.store.reload()
		h.viewModel.migrateClientState(from: "Alpine", to: "Alpine 2", .renamed)
		await h.store.reload()   // the agent hasn't renamed it yet in this list
		#expect(h.canvases.canvases["Alpine 2"]?.allOpenTabs.contains(Self.console) == true)
		#expect(h.canvases.canvases["Alpine"] == nil)
		try Self.rename(h, "Alpine", to: "Alpine 2")
		await h.store.reload()
		#expect(h.canvases.canvases["Alpine 2"]?.allOpenTabs.contains(Self.console) == true)
	}

	// A copy duplicated in Finder (same created date) listed beside its original never takes
	// the original's state, even while the original is missing from one list.
	@Test("T34: a VM listed beside an absent VM on its date takes none of its state")
	func aTwinAlreadyListedTakesNothing() async throws {
		let h = await DesktopHarness.make(Self.library())
		h.open(Self.console, vm: "Alpine")
		let alpine = try #require(h.stub.vms["Alpine"])
		var twin = alpine
		twin.name = "Alpine copy"
		h.stub.vms["Alpine copy"] = twin
		await h.store.reload()
		h.stub.vms["Alpine"] = nil
		await h.store.reload()
		h.stub.vms["Alpine"] = alpine
		await h.store.reload()
		#expect(h.canvases.canvases["Alpine copy"] == nil)
		#expect(h.canvases.canvas(for: "Alpine").allOpenTabs.contains(Self.console))
	}

	// A name still holding a deleted VM's state (T33 keeps it) taken by a renamed VM: the
	// stale state goes and the renamed VM's comes along.
	@Test("T34: a VM renamed onto a name holding stale state keeps its own layout")
	func aRenameOntoStaleStateKeepsItsOwn() async throws {
		let h = await DesktopHarness.make(Self.library())
		h.open(.config, vm: "Debian")
		h.open(Self.console, vm: "Alpine")
		await h.store.reload()
		h.stub.vms["Debian"] = nil   // deleted elsewhere: its layout stays (T33)
		await h.store.reload()
		try Self.rename(h, "Alpine", to: "Debian")
		await h.store.reload()
		let debian = h.canvases.canvas(for: "Debian").allOpenTabs
		#expect(debian.contains(Self.console))
		#expect(!debian.contains(.config))
		#expect(h.canvases.canvases["Alpine"] == nil)
	}

	@Test("T34: two VMs that swap names elsewhere keep their own layouts")
	func aSwapKeepsEachLayout() async throws {
		let h = await DesktopHarness.make(Self.library())
		h.open(.config, vm: "Debian")
		h.open(Self.console, vm: "Alpine")
		await h.store.reload()
		let alpine = try #require(h.stub.vms["Alpine"])
		let debian = try #require(h.stub.vms["Debian"])
		var a = alpine, d = debian
		a.name = "Debian"
		d.name = "Alpine"
		h.stub.vms["Debian"] = a
		h.stub.vms["Alpine"] = d
		await h.store.reload()
		#expect(h.canvases.canvas(for: "Debian").allOpenTabs.contains(Self.console))
		#expect(!h.canvases.canvas(for: "Debian").allOpenTabs.contains(.config))
		#expect(h.canvases.canvas(for: "Alpine").allOpenTabs.contains(.config))
	}

	// The rename moves everything this desktop's own renames move: the selection follows,
	// and a torn window is reopened under the new name rather than closed (T3).
	@Test("T34: a selected VM renamed elsewhere stays selected and its torn window follows")
	func theSelectionAndTornWindowsFollow() async throws {
		let h = await DesktopHarness.make(Self.library())
		h.open(Self.console, vm: "Alpine")
		h.viewModel.select(name: "Alpine")
		await h.store.reload()
		let torn = h.viewModel.tearOff(Self.console, vm: "Alpine")
		var orders: [TornTabRegistry.Order] = []
		let watch = h.tornTabs.$orders.sink { all in
			if let order = all[torn] { orders.append(order) }
		}
		try Self.rename(h, "Alpine", to: "Bookworm")
		await h.store.reload()
		watch.cancel()
		#expect(h.viewModel.selectedName == "Bookworm")
		#expect(orders == [.reopen(as: TornTab(vm: "Bookworm", tab: torn.tab))])
	}
}
