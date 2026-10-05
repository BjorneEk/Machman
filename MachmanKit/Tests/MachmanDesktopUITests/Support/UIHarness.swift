//
//  UIHarness.swift
//  MachmanDesktopUITests
//
//  The desktop's client stack for hosted views, wired the way the render tool's SceneContext
//  (Tools/MachmanRender/SceneContext.swift) and DesktopCoreTests' DesktopHarness wire it: a
//  StubMachman serving sample VMs, the stores attached to it, a VMListViewModel over them,
//  the persisted stores in the run's scratch space. Kept apart from DesktopHarness on
//  purpose (r3-ta T12): view-model tests churn it, and these tests need real SwiftTerm
//  sessions (TerminalSessions.swiftTerm(), whose controllers exist only once a tab opens —
//  no test here opens one, so nothing spawns ssh). PreviewService stays unattached (no
//  polling), and the pasteboard watch is a fake that never reads NSPasteboard.general.
//

import Foundation
import SwiftUI
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

@MainActor
final class UIHarness {
	let stub: StubMachman
	let store = VMStore()
	let operations = OperationsStore()
	let canvases: CanvasStateStore
	let profiles: TerminalProfileStore
	let previews: PreviewService
	let tornTabs = TornTabRegistry()
	let terminals = TerminalSessions.swiftTerm()
	let pasteboard = PasteboardWatch(triggers: [], changeCount: { 0 }, read: { .empty })
	let viewModel: VMListViewModel

	private init(vms: [VMInfo]) {
		stub = StubMachman.serving(vms)
		let dir = TestEnvironment.scratchURL.appendingPathComponent(UUID().uuidString)
		canvases = CanvasStateStore(fileURL: dir.appendingPathComponent("Canvas.json"))
		profiles = TerminalProfileStore(fileURL: dir.appendingPathComponent("Profiles.json"))
		previews = PreviewService(store: store)
		store.attach(api: stub)
		operations.attach(api: stub)
		viewModel = VMListViewModel(
			api: stub, store: store, operations: operations, terminals: terminals,
			previews: previews, canvases: canvases, tornTabs: tornTabs)
	}

	// Returns once the list has landed, with `select` (default: the first VM) selected.
	static func make(_ vms: [VMInfo] = Samples.library(), select: String? = nil) async
		-> UIHarness {
		let harness = UIHarness(vms: vms)
		_ = await eventually { harness.store.vms.count == vms.count }
		harness.viewModel.select(name: select ?? vms.first?.name)
		return harness
	}

	func vm(_ name: String) -> VMInfo {
		guard let vm = viewModel.vms.first(where: { $0.name == name }) else {
			preconditionFailure("UIHarness serves no VM named \(name)")
		}
		return vm
	}

	// `view`'s accessibility tree, hosted offscreen (OffscreenHost.withHost).
	func snapshot(
		_ view: some View, width: CGFloat? = nil, height: CGFloat? = nil,
		chrome: OffscreenHost.Chrome = .none
	) async throws -> AXSnapshot {
		try await OffscreenHost.withHost(view, width: width, height: height, chrome: chrome) {
			$0.snapshot()
		}
	}
}
