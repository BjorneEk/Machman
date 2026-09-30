import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

// Every path that takes a terminal tab away tears its controller down.
@MainActor
struct TabCloseTests {
	private let console = SerialPortRef(kind: .console, index: 0)

	@Test func closeActiveTabDropsTheController() async throws {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		h.open(.terminal(console), vm: "Debian")
		h.terminals.ensureController(
			vm: "Debian", ref: console, socketPath: "/nonexistent.sock",
			profile: h.profiles.defaultProfile)
		#expect(await eventually { h.terminals.controller(vm: "Debian", ref: console) != nil })
		#expect(h.viewModel.closeActiveTab())
		#expect(h.terminals.controller(vm: "Debian", ref: console) == nil)
		#expect(h.controllers.first?.disconnects == 1)
	}

	@Test func aRemovedPortClosesItsTabOnTheNextList() async throws {
		let h = await DesktopHarness.make()
		h.open(.terminal(console), vm: "Debian")
		h.terminals.ensureController(
			vm: "Debian", ref: console, socketPath: nil, profile: h.profiles.defaultProfile)
		#expect(await eventually { h.terminals.controller(vm: "Debian", ref: console) != nil })
		try await h.stub.removeConsolePort(vm: "Debian")   // emits listChanged
		#expect(await eventually {
			!h.canvases.canvas(for: "Debian").allOpenTabs.contains(.terminal(self.console))
		})
		#expect(h.controllers.first?.disconnects == 1)
	}

	@Test func aDeletedVMOrdersItsTornWindowsClosed() async throws {
		let h = await DesktopHarness.make()
		let torn = TornTab(vm: "Alpine", tab: .terminal(console))
		h.tornTabs.open.insert(torn)
		try await h.stub.deleteVM(named: "Alpine")
		#expect(await eventually { h.tornTabs.orders[torn] == .close })
	}
}
