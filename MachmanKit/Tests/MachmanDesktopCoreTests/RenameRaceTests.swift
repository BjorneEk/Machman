//
//  RenameRaceTests.swift
//  MachmanDesktopCoreTests
//
//  A rename's client state (terminals, ssh sessions, the canvas layout, the last frame) moves
//  to the new name. The daemon announces the rename before it replies, so the list without
//  the old name could land first: the refresh took the VM for gone, closed its tabs and
//  dropped its terminals before the reply could move them (T16). And the torn windows' swap
//  was posted after that refresh had ordered them closed. Whichever lands first now moves
//  the state, and the refresh that shows the new name swaps the windows.
//

import Testing
import Foundation
import Combine
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct RenameRaceTests {
	private let console = SerialPortRef(kind: .console, index: 0)

	// Debian, shown, with its Console 0 tab open and its terminal live.
	private func debianWithConsole() async throws -> (DesktopHarness, any TerminalController) {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		h.open(.terminal(console), vm: "Debian")
		let socket = try #require(
			h.viewModel.vms.first { $0.name == "Debian" }?.consolePorts?.first?.socketPath)
		h.terminals.ensureController(
			vm: "Debian", ref: console, socketPath: socket, profile: h.profiles.defaultProfile)
		#expect(await eventually { h.terminals.controller(vm: "Debian", ref: console) != nil })
		return (h, try #require(h.terminals.controller(vm: "Debian", ref: console)))
	}

	private func keptItsState(
		_ h: DesktopHarness, _ live: any TerminalController
	) -> Bool {
		h.canvases.canvas(for: "Debian 2").allOpenTabs.contains(.terminal(console))
			&& h.terminals.controller(vm: "Debian 2", ref: console) === live
			&& h.terminals.controller(vm: "Debian", ref: console) == nil
	}

	@Test("T16: a list that lands before the rename's reply keeps the VM's tabs and terminals")
	func aListBeforeTheReplyKeepsTheState() async throws {
		let (h, live) = try await debianWithConsole()
		let gate = ReplyGate()
		h.stub.pause = { method in
			if method == "renameVM" { await gate.wait() }
		}
		let renaming = Task { await h.viewModel.rename(from: "Debian", to: "Debian 2") }
		// The reply is held: this is the event's list.
		#expect(await eventually { h.store.vms.contains { $0.name == "Debian 2" } })
		#expect(keptItsState(h, live))
		#expect(h.viewModel.selectedName == "Debian 2")
		gate.open()
		#expect(await renaming.value)
		#expect(keptItsState(h, live))
		#expect(h.viewModel.selectedName == "Debian 2")
	}

	// The other order: the reply moves the state while the list is still on its way, and a
	// row patched in between republishes the list without the new name.
	@Test("T16: a list or row update that predates the rename keeps the moved state")
	func anOlderListKeepsTheMovedState() async throws {
		let (h, live) = try await debianWithConsole()
		let gate = ReplyGate()
		h.stub.pause = { method in
			if method == "listVMs" { await gate.wait() }   // every list is held back
		}
		let renaming = Task { await h.viewModel.rename(from: "Debian", to: "Debian 2") }
		#expect(await eventually { h.terminals.controller(vm: "Debian 2", ref: console) === live })
		h.stub.emit(.stateChanged(vm: "Alpine", state: .running))
		#expect(await eventually { h.store.vms.first { $0.name == "Alpine" }?.state == .running })
		#expect(keptItsState(h, live))
		gate.open()
		#expect(await renaming.value)
		#expect(keptItsState(h, live))
		#expect(h.viewModel.selectedName == "Debian 2")
	}

	@Test("T16: a rename never orders its torn windows to close")
	func aRenameNeverClosesItsTornWindows() async throws {
		let (h, live) = try await debianWithConsole()
		let torn = h.viewModel.tearOff(.terminal(console), vm: "Debian")
		var orders: [TornTabRegistry.Order] = []
		let watch = h.tornTabs.$orders.sink { all in
			if let order = all[torn] { orders.append(order) }
		}
		#expect(await h.viewModel.rename(from: "Debian", to: "Debian 2"))
		watch.cancel()
		let swap = TornTabRegistry.Order.reopen(as: TornTab(vm: "Debian 2", tab: torn.tab))
		#expect(orders == [swap])
		#expect(h.terminals.controller(vm: "Debian 2", ref: console) === live)
	}
}
