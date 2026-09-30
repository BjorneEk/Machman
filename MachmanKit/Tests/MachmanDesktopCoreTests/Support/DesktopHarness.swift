//
//  DesktopHarness.swift
//  MachmanDesktopCoreTests
//
//  The desktop's client stack wired the way DaemonConnection wires it, over a StubMachman:
//  stores attached, a VMListViewModel over them, terminal sessions making fakes, and the
//  persisted stores in the run's scratch space. `await DesktopHarness.make(...)` returns
//  once the first list has landed and the first VM is selected — the app's launch state.
//  One difference, on purpose: PreviewService is built but not attached. Attached, it polls
//  stub.preview every 4 s for the selected running VM, dropping "preview" into stub.calls at
//  arbitrary points; a preview test attaches it itself (`h.previews.attach(api: h.stub)`).
//

import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
final class DesktopHarness {
	let stub: StubMachman
	let store = VMStore()
	let operations = OperationsStore()
	let canvases: CanvasStateStore
	let profiles: TerminalProfileStore
	let previews: PreviewService
	let tornTabs = TornTabRegistry()
	private(set) var controllers: [FakeTerminalController] = []
	private(set) var terminals: TerminalSessions!
	private(set) var viewModel: VMListViewModel!

	private init(vms: [VMInfo]) {
		stub = StubMachman.serving(vms)
		let dir = TestEnvironment.scratchURL.appendingPathComponent(UUID().uuidString)
		canvases = CanvasStateStore(fileURL: dir.appendingPathComponent("Canvas.json"))
		profiles = TerminalProfileStore(fileURL: dir.appendingPathComponent("Profiles.json"))
		previews = PreviewService(store: store)
		terminals = TerminalSessions { [unowned self] profile in
			let controller = FakeTerminalController(profile: profile)
			self.controllers.append(controller)
			return controller
		}
		store.attach(api: stub)
		operations.attach(api: stub)
		viewModel = VMListViewModel(
			api: stub, store: store, operations: operations, terminals: terminals,
			previews: previews, canvases: canvases, tornTabs: tornTabs)
	}

	static func make(_ vms: [VMInfo] = Samples.library()) async -> DesktopHarness {
		let harness = DesktopHarness(vms: vms)
		_ = await eventually { harness.viewModel.selectedName != nil || vms.isEmpty }
		return harness
	}

	// Open a canvas tab the way the tree/canvas do.
	func open(_ tab: VMPaneTab, vm: String) {
		var canvas = canvases.canvas(for: vm)
		canvas.open(tab)
		canvases.setCanvas(canvas, for: vm)
	}
}
