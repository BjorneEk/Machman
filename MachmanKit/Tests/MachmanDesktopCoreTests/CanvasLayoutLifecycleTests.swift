//
//  CanvasLayoutLifecycleTests.swift
//  MachmanDesktopCoreTests
//
//  A VM's saved canvas layout against the VM's lifecycle (T33): every landed list pruned the
//  layouts of the VMs it didn't show, so a VM missing from one list (an external library
//  asleep, a config that briefly failed to load) lost its tabs for good. The layout now goes
//  the way port profiles do (T29): with this desktop's delete, or when a new VM takes the name.
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
struct CanvasLayoutLifecycleTests {
	private static let console = VMPaneTab.terminal(SerialPortRef(kind: .console, index: 0))

	@Test("T33: a VM missing from one list keeps its canvas layout when it comes back")
	func aVMMissingFromOneListKeepsItsLayout() async throws {
		let h = await DesktopHarness.make()
		h.open(Self.console, vm: "Alpine")
		await h.store.reload()
		let alpine = try #require(h.stub.vms["Alpine"])
		h.stub.vms["Alpine"] = nil
		await h.store.reload()
		#expect(!h.viewModel.vms.contains { $0.name == "Alpine" })
		#expect(h.canvases.canvases["Alpine"] != nil)
		h.stub.vms["Alpine"] = alpine
		await h.store.reload()
		#expect(h.canvases.canvas(for: "Alpine").allOpenTabs.contains(Self.console))
	}

	// Deleted elsewhere and its name taken again: the created date tells the new VM apart.
	@Test("T33: a new VM under a deleted one's name starts on a fresh canvas layout")
	func aNewVMUnderAnOldNameStartsFresh() async throws {
		let h = await DesktopHarness.make()
		h.open(Self.console, vm: "Alpine")
		await h.store.reload()   // a list shows the VM the layout belongs to
		var reborn = try #require(h.stub.vms["Alpine"])
		reborn.created = reborn.created.addingTimeInterval(86_400)
		h.stub.vms["Alpine"] = reborn
		h.stub.emit(.listChanged)
		#expect(await eventually { h.canvases.canvases["Alpine"] == nil })
	}

	@Test("T33: a VM deleted from this desktop takes its canvas layout along")
	func aDeletedVMsLayoutIsForgotten() async throws {
		let h = await DesktopHarness.make()
		h.open(Self.console, vm: "Alpine")
		let alpine = try #require(h.viewModel.vms.first { $0.name == "Alpine" })
		h.viewModel.performDeleteVM(alpine)
		#expect(await eventually { !h.viewModel.vms.contains { $0.name == "Alpine" } })
		#expect(h.canvases.canvases["Alpine"] == nil)
	}

	// A layouts file from before records no dates: it reads, and learns each from a list.
	@Test("T33: a layouts file without created dates reads, and learns them from a list")
	func anOlderFileLearnsItsDates() async throws {
		let url = TestEnvironment.scratchURL.appendingPathComponent(UUID().uuidString)
			.appendingPathComponent("Canvas.json")
		let older = CanvasStateStore(fileURL: url, saveDelay: .zero)
		var canvas = CanvasState()
		canvas.open(Self.console)
		older.setCanvas(canvas, for: "Alpine")
		older.flush()
		let alpine = try #require(Samples.library().first { $0.name == "Alpine" })
		let store = CanvasStateStore(fileURL: url, saveDelay: .zero)
		store.listed([alpine])
		#expect(store.canvases["Alpine"] != nil)
		var reborn = alpine
		reborn.created = alpine.created.addingTimeInterval(86_400)
		store.listed([reborn])
		#expect(store.canvases["Alpine"] == nil)
	}
}
