//
//  TabCloseAskTests.swift
//  MachmanDesktopCoreTests
//
//  Closing a connected SSH session asks first (H42, choice C3). Every close path — ⌘W, the
//  tab's icon area, its Close Tab, the tree's and the inspector's Close Session — ended a
//  remote shell and its scrollback at once; one stray ⌘W lost a session. Serial tabs only
//  disconnect (the guest keeps running) and the configuration tab holds nothing: they close
//  at once, as does a session whose ssh already ended.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct TabCloseAskTests {
	private let console = SerialPortRef(kind: .console, index: 0)

	// Debian with `titles` open as connected ssh tabs, the last one active; asking on.
	private func sessions(_ titles: [String]) async -> (DesktopHarness, [SSHSessionRef]) {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		h.viewModel.sshCloseAskOverride = true
		var refs: [SSHSessionRef] = []
		for title in titles {
			let ref = SSHSessionRef(title: title)
			h.open(.ssh(ref), vm: "Debian")
			h.terminals.ensureSSHController(
				vm: "Debian", ref: ref, arguments: ["debian.machman"],
				profile: h.profiles.defaultProfile)
			_ = await eventually {
				h.terminals.sshController(vm: "Debian", ref: ref)?.connected == true
			}
			refs.append(ref)
		}
		return (h, refs)
	}

	private func isOpen(_ h: DesktopHarness, _ tab: VMPaneTab) -> Bool {
		h.canvases.canvas(for: "Debian").allOpenTabs.contains(tab)
	}

	@Test func aConnectedSessionAsksAndStaysOpen() async throws {
		let (h, refs) = await sessions(["Session 1"])
		let ref = try #require(refs.first)
		#expect(h.viewModel.closeAsks(.ssh(ref), vm: "Debian"))
		h.viewModel.requestCloseTab(.ssh(ref), vm: "Debian")
		#expect(h.viewModel.pendingTabClose?.tab == .ssh(ref))
		#expect(h.viewModel.pendingTabClose?.name == "Session 1")
		#expect(VMListViewModel.closeSessionTitle("Session 1")
			== "Close \u{201C}Session 1\u{201D}?")
		#expect(isOpen(h, .ssh(ref)))
		#expect(h.controllers.first?.disconnects == 0)
	}

	@Test func confirmingClosesTheTabAndEndsTheSession() async throws {
		let (h, refs) = await sessions(["Session 1"])
		let ref = try #require(refs.first)
		h.viewModel.requestCloseTab(.ssh(ref), vm: "Debian")
		let pending = try #require(h.viewModel.pendingTabClose)
		h.viewModel.confirmTabClose(pending)
		#expect(!isOpen(h, .ssh(ref)))
		#expect(h.terminals.sshController(vm: "Debian", ref: ref) == nil)
		#expect(h.controllers.first?.disconnects == 1)
	}

	@Test func dontAskAgainClosesAtOnce() async throws {
		let (h, refs) = await sessions(["Session 1"])
		let ref = try #require(refs.first)
		h.viewModel.sshCloseAskOverride = false
		h.viewModel.requestCloseTab(.ssh(ref), vm: "Debian")
		#expect(h.viewModel.pendingTabClose == nil)
		#expect(!isOpen(h, .ssh(ref)))
	}

	@Test func anEndedSessionClosesAtOnce() async throws {
		let (h, refs) = await sessions(["Session 1"])
		let ref = try #require(refs.first)
		h.terminals.sshController(vm: "Debian", ref: ref)?.disconnect()
		h.viewModel.requestCloseTab(.ssh(ref), vm: "Debian")
		#expect(h.viewModel.pendingTabClose == nil)
		#expect(!isOpen(h, .ssh(ref)))
	}

	@Test func serialAndConfigurationTabsCloseAtOnce() async {
		let h = await DesktopHarness.make()
		h.viewModel.select(name: "Debian")
		h.viewModel.sshCloseAskOverride = true
		h.open(.config, vm: "Debian")
		h.open(.terminal(console), vm: "Debian")
		h.viewModel.requestCloseTab(.terminal(console), vm: "Debian")
		h.viewModel.requestCloseTab(.config, vm: "Debian")
		#expect(h.viewModel.pendingTabClose == nil)
		#expect(h.canvases.canvas(for: "Debian").allOpenTabs.isEmpty)
	}

	@Test func commandWOnALiveSessionAsksAndCountsAsHandled() async throws {
		let (h, refs) = await sessions(["Session 1"])
		let ref = try #require(refs.first)
		#expect(h.viewModel.closeActiveTab())
		#expect(h.viewModel.pendingTabClose?.tab == .ssh(ref))
		#expect(isOpen(h, .ssh(ref)))
	}

	@Test func questionsQueueOneAtATime() async throws {
		let (h, refs) = await sessions(["Session 1", "Session 2"])
		for ref in refs { h.viewModel.requestCloseTab(.ssh(ref), vm: "Debian") }
		#expect(h.viewModel.pendingTabClose?.tab == .ssh(refs[0]))
		h.viewModel.isTabClosePresented = false
		#expect(await eventually { h.viewModel.pendingTabClose?.tab == .ssh(refs[1]) })
	}

	@Test func aTornSessionAsksInItsOwnWindow() async throws {
		let (h, refs) = await sessions(["Session 1"])
		let ref = try #require(refs.first)
		let torn = h.viewModel.tearOff(.ssh(ref), vm: "Debian")
		h.viewModel.requestCloseTab(.ssh(ref), vm: "Debian", from: torn)
		#expect(h.viewModel.pendingTabClose?.window == torn)
	}

	// Review F17: a question asked in a torn window that then went away by an order stayed
	// showing for no window, and every later close question queued behind it for good.
	@Test func aQuestionFromAWindowThatWentAwayGivesWay() async throws {
		let (h, refs) = await sessions(["Session 1", "Session 2"])
		let torn = h.viewModel.tearOff(.ssh(refs[0]), vm: "Debian")
		h.viewModel.requestCloseTab(.ssh(refs[0]), vm: "Debian", from: torn)
		#expect(h.viewModel.pendingTabClose?.window == torn)
		// The window goes by an order (the reconcile's close), not by the user.
		h.tornTabs.closing.insert(torn)
		VMListViewModel.tornWindowClosed(
			torn, registry: h.tornTabs, terminals: h.terminals, viewModel: h.viewModel)
		h.viewModel.requestCloseTab(.ssh(refs[1]), vm: "Debian")
		#expect(await eventually { h.viewModel.pendingTabClose?.tab == .ssh(refs[1]) })
		let pending = try #require(h.viewModel.pendingTabClose)
		#expect(pending.window == nil)
		h.viewModel.confirmTabClose(pending)
		#expect(!isOpen(h, .ssh(refs[1])))
	}
}
