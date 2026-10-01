//
//  SafeSaveTests.swift
//  MachmanDesktopCoreTests
//
//  Save as New VM hands the running safe run to a new name (T17). The daemon keeps the
//  original, stopped; the desktop must move the run's client state with it — as a rename
//  does — or the original's console keeps typing into the saved run and never connects to
//  the original's own socket when it starts again.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct SafeSaveTests {
	private let console = SerialPortRef(kind: .console, index: 0)

	// A safe run of Debian with its Console 0 tab open and connected; the stub keeps the
	// original after a save, as the engine does.
	private func runWithConsole() async throws -> (DesktopHarness, any TerminalController) {
		let h = await DesktopHarness.make([Samples.linuxSafeRun("Debian")])
		h.stub.safeSaveKeepsOriginal = true
		h.viewModel.select(name: "Debian")
		h.open(.terminal(console), vm: "Debian")
		let debian = try #require(h.viewModel.vms.first)
		let socket = try #require(debian.consolePorts?.first?.socketPath)
		h.terminals.ensureController(
			vm: "Debian", ref: console, socketPath: socket, profile: h.profiles.defaultProfile)
		#expect(await eventually { h.terminals.controller(vm: "Debian", ref: console) != nil })
		let live = try #require(h.terminals.controller(vm: "Debian", ref: console))
		return (h, live)
	}

	@Test func theRunsTerminalMovesToTheSavedVM() async throws {
		let (h, live) = try await runWithConsole()
		h.viewModel.safeSave("Debian", to: "Debian kept")
		#expect(await eventually { h.viewModel.selectedName == "Debian kept" })
		#expect(h.terminals.controller(vm: "Debian kept", ref: console) === live)
		#expect(h.terminals.controller(vm: "Debian", ref: console) == nil)
		#expect(h.canvases.canvas(for: "Debian kept").allOpenTabs.contains(.terminal(console)))
		#expect(h.viewModel.hasVM("Debian"))
	}

	// The old controller stayed under the original's name, so starting the original again
	// found it "connected" and never connected to the original's new socket.
	@Test func theOriginalConnectsAfreshLater() async throws {
		let (h, _) = try await runWithConsole()
		h.viewModel.safeSave("Debian", to: "Debian kept")
		#expect(await eventually { h.viewModel.selectedName == "Debian kept" })
		let restart = "/var/empty/machman-sample/Debian-restart.sock"
		h.terminals.ensureController(
			vm: "Debian", ref: console, socketPath: restart, profile: h.profiles.defaultProfile)
		#expect(await eventually { h.controllers.count == 2 })
		#expect(h.controllers.last?.connectedPaths == [restart])
	}

	@Test func aTornConsoleFollowsTheRun() async throws {
		let h = await DesktopHarness.make([Samples.linuxSafeRun("Debian")])
		h.stub.safeSaveKeepsOriginal = true
		let torn = TornTab(vm: "Debian", tab: .terminal(console))
		h.tornTabs.open.insert(torn)
		h.viewModel.safeSave("Debian", to: "Debian kept")
		#expect(await eventually {
			h.tornTabs.orders[torn]
				== .reopen(as: TornTab(vm: "Debian kept", tab: .terminal(self.console)))
		})
	}
}
