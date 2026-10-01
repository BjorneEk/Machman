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

	// T19: the SSH session inspector's Close Session took only the canvas half of a close —
	// no row pruning, no torn-window branch. Every close site now runs closeTab.
	@Test func closingASessionTabEndsSshAndItsRow() async throws {
		let h = await DesktopHarness.make()
		let session = SSHSessionRef(title: "Session 1")
		h.viewModel.select(name: "Debian")
		h.open(.ssh(session), vm: "Debian")
		h.terminals.ensureSSHController(
			vm: "Debian", ref: session, arguments: ["debian.machman"],
			profile: h.profiles.defaultProfile)
		#expect(await eventually { h.terminals.sshController(vm: "Debian", ref: session) != nil })
		h.viewModel.treeSelection = [.sshSession(session)]
		h.viewModel.closeTab(.ssh(session), vm: "Debian")
		#expect(h.terminals.sshController(vm: "Debian", ref: session) == nil)
		#expect(h.controllers.first?.disconnects == 1)
		#expect(!h.canvases.canvas(for: "Debian").allOpenTabs.contains(.ssh(session)))
		#expect(h.viewModel.treeSelection.isEmpty)
	}

	// A torn tab IS its window: closing it orders the window closed, and the window's
	// teardown ends the session (not the close itself — that would strand the window).
	@Test func closingATornSessionOrdersItsWindowClosed() async throws {
		let h = await DesktopHarness.make()
		let session = SSHSessionRef(title: "Session 1")
		let torn = TornTab(vm: "Debian", tab: .ssh(session))
		h.terminals.ensureSSHController(
			vm: "Debian", ref: session, arguments: ["debian.machman"],
			profile: h.profiles.defaultProfile)
		#expect(await eventually { h.terminals.sshController(vm: "Debian", ref: session) != nil })
		h.tornTabs.open.insert(torn)
		h.viewModel.closeTab(.ssh(session), vm: "Debian")
		#expect(h.tornTabs.orders[torn] == .close)
		#expect(h.terminals.sshController(vm: "Debian", ref: session) != nil)
		#expect(h.controllers.first?.disconnects == 0)
	}

	@Test func aTornWindowsTeardownEndsItsTerminal() async throws {
		let h = await DesktopHarness.make()
		let torn = TornTab(vm: "Debian", tab: .terminal(console))
		h.viewModel.select(name: "Debian")
		h.terminals.ensureController(
			vm: "Debian", ref: console, socketPath: nil, profile: h.profiles.defaultProfile)
		#expect(await eventually { h.terminals.controller(vm: "Debian", ref: console) != nil })
		h.tornTabs.open.insert(torn)
		h.viewModel.treeSelection = [.serial(console)]
		VMListViewModel.tornWindowClosed(
			torn, registry: h.tornTabs, terminals: h.terminals, viewModel: h.viewModel)
		#expect(!h.tornTabs.open.contains(torn))
		#expect(h.terminals.controller(vm: "Debian", ref: console) == nil)
		#expect(h.viewModel.treeSelection.isEmpty)
	}

	// Mid-reconnect there is no view model; the window's terminal still ends.
	@Test func aTornWindowClosingWithoutAViewModelStillEndsItsTerminal() async throws {
		let h = await DesktopHarness.make()
		let torn = TornTab(vm: "Debian", tab: .terminal(console))
		h.terminals.ensureController(
			vm: "Debian", ref: console, socketPath: nil, profile: h.profiles.defaultProfile)
		#expect(await eventually { h.terminals.controller(vm: "Debian", ref: console) != nil })
		h.tornTabs.open.insert(torn)
		VMListViewModel.tornWindowClosed(
			torn, registry: h.tornTabs, terminals: h.terminals, viewModel: nil)
		#expect(!h.tornTabs.open.contains(torn))
		#expect(h.terminals.controller(vm: "Debian", ref: console) == nil)
		#expect(h.controllers.first?.disconnects == 1)
	}

	// The reconcile used to keep only rename swaps, so a close posted just before a list
	// refresh was wiped before its window could act on it.
	@Test func aPostedCloseOrderSurvivesAListRefresh() async throws {
		let h = await DesktopHarness.make()
		let torn = TornTab(vm: "Debian", tab: .config)
		h.tornTabs.open.insert(torn)
		h.tornTabs.orders[torn] = .close
		await h.viewModel.reload()
		#expect(h.tornTabs.orders[torn] == .close)
	}

	// The port reconcile closed the tab and its terminal but left the row selected.
	@Test func aRemovedPortsRowIsDeselected() async throws {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		h.open(.terminal(console), vm: "Debian")
		h.viewModel.treeSelection = [.serial(console)]
		try await h.stub.removeConsolePort(vm: "Debian")   // emits listChanged
		#expect(await eventually { h.viewModel.treeSelection.isEmpty })
	}

	@Test func aDeletedVMOrdersItsTornWindowsClosed() async throws {
		let h = await DesktopHarness.make()
		let torn = TornTab(vm: "Alpine", tab: .terminal(console))
		h.tornTabs.open.insert(torn)
		try await h.stub.deleteVM(named: "Alpine")
		#expect(await eventually { h.tornTabs.orders[torn] == .close })
	}
}
