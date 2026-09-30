//
//  SceneContext.swift
//  MachmanRender
//
//  The state a scene draws from, built the way DaemonConnection builds the app's: stores
//  attached to a StubMachman serving sample VMs, a VMListViewModel over them, SwiftTerm
//  terminal sessions, and profile/canvas stores persisting into the render sandbox. Fresh
//  per scene, so no scene sees another's selection or tabs.
//

import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

@MainActor
final class SceneContext {
	let stub: StubMachman
	let store = VMStore()
	let operations = OperationsStore()
	let terminals = TerminalSessions.swiftTerm()
	let canvases: CanvasStateStore
	let profiles: TerminalProfileStore
	let previews: PreviewService
	let tornTabs = TornTabRegistry()
	let viewModel: VMListViewModel

	private static var counter = 0

	// `vms` are served by the stub; `select` picks the shown VM (default: the first).
	init(vms: [VMInfo] = Samples.library(), select: String? = nil) {
		Self.counter += 1
		let dir = RenderSandbox.dataDir.appendingPathComponent("scene-\(Self.counter)")
		stub = StubMachman.serving(vms)
		canvases = CanvasStateStore(fileURL: dir.appendingPathComponent("CanvasLayouts.json"))
		profiles = TerminalProfileStore(
			fileURL: dir.appendingPathComponent("TerminalProfiles.json"))
		previews = PreviewService(store: store)
		store.attach(api: stub)
		operations.attach(api: stub)
		viewModel = VMListViewModel(
			api: stub, store: store, operations: operations, terminals: terminals,
			previews: previews, canvases: canvases, tornTabs: tornTabs)
		// The list lands asynchronously (as it does from the daemon); wait for it, then
		// select like the app's launch path does.
		Offscreen.pump(until: { self.store.vms.count == vms.count })
		viewModel.select(name: select ?? vms.first?.name)
	}

	var vm: VMInfo { viewModel.selected! }

	func vm(_ name: String) -> VMInfo {
		viewModel.vms.first { $0.name == name }!
	}
}
