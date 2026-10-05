//
//  TornDockTests.swift
//  MachmanDesktopCoreTests
//
//  Closing a torn-off SSH window doesn't end its session (C18): while ssh runs, the session
//  docks back into its VM's canvas as a tab, live terminal and all. Ending it stays Close
//  Session, which asks (C3) and orders the window closed — that close ends it. A window
//  whose session already ended just closes.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct TornDockTests {
	// Debian's Session 1, connected and torn into its own window.
	private func tornSession() async -> (DesktopHarness, SSHSessionRef, TornTab) {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		let ref = SSHSessionRef(title: "Session 1")
		h.open(.ssh(ref), vm: "Debian")
		h.terminals.ensureSSHController(
			vm: "Debian", ref: ref, arguments: ["debian.machman"],
			profile: h.profiles.defaultProfile)
		_ = await eventually {
			h.terminals.sshController(vm: "Debian", ref: ref)?.connected == true
		}
		let torn = h.viewModel.tearOff(.ssh(ref), vm: "Debian")
		return (h, ref, torn)
	}

	private func windowClosed(_ h: DesktopHarness, _ torn: TornTab) {
		VMListViewModel.tornWindowClosed(
			torn, registry: h.tornTabs, terminals: h.terminals, viewModel: h.viewModel)
	}

	@Test func closingTheWindowOfALiveSessionDocksItBack() async {
		let (h, ref, torn) = await tornSession()
		windowClosed(h, torn)
		#expect(!h.tornTabs.open.contains(torn))
		#expect(h.canvases.canvas(for: "Debian").activeTab == .ssh(ref))
		#expect(h.terminals.sshController(vm: "Debian", ref: ref) != nil)
		#expect(h.controllers.first?.disconnects == 0)
	}

	@Test func theWindowOfAnEndedSessionJustCloses() async {
		let (h, ref, torn) = await tornSession()
		h.terminals.sshController(vm: "Debian", ref: ref)?.disconnect()
		windowClosed(h, torn)
		#expect(!h.canvases.canvas(for: "Debian").allOpenTabs.contains(.ssh(ref)))
		#expect(h.terminals.sshController(vm: "Debian", ref: ref) == nil)
	}

	@Test func closeSessionEndsItInsteadOfDocking() async throws {
		let (h, ref, torn) = await tornSession()
		h.viewModel.sshCloseAskOverride = false
		h.viewModel.requestCloseTab(.ssh(ref), vm: "Debian", from: torn)
		#expect(h.tornTabs.orders[torn] == .close)
		// The window acts on its order (TornTabWindowView.resolve), then goes.
		h.tornTabs.orders[torn] = nil
		h.tornTabs.closing.insert(torn)
		windowClosed(h, torn)
		#expect(!h.canvases.canvas(for: "Debian").allOpenTabs.contains(.ssh(ref)))
		#expect(h.terminals.sshController(vm: "Debian", ref: ref) == nil)
		#expect(h.tornTabs.closing.isEmpty)
	}

	@Test func aSerialWindowStillClosesItsTerminal() async {
		let h = await DesktopHarness.make()
		let console = SerialPortRef(kind: .console, index: 0)
		h.terminals.ensureController(
			vm: "Debian", ref: console, socketPath: "/var/empty/x.sock",
			profile: h.profiles.defaultProfile)
		_ = await eventually { h.terminals.controller(vm: "Debian", ref: console) != nil }
		let torn = TornTab(vm: "Debian", tab: .terminal(console))
		h.tornTabs.open.insert(torn)
		windowClosed(h, torn)
		#expect(h.terminals.controller(vm: "Debian", ref: console) == nil)
		#expect(!h.canvases.canvas(for: "Debian").allOpenTabs.contains(.terminal(console)))
	}
}
