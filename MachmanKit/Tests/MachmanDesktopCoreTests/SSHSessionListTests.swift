//
//  SSHSessionListTests.swift
//  MachmanDesktopCoreTests
//
//  What the sidebar's SSH section lists (T20): canvas session tabs and torn session windows
//  whose ssh still runs. A window the system restored after a relaunch holds no session, so
//  it gets no row, no dot and no count — and new sessions number past every listed one.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct SSHSessionListTests {
	private let canvasSession = SSHSessionRef(title: "Session 1")
	private let tornSession = SSHSessionRef(title: "Session 1")

	private func startSession(_ h: DesktopHarness, _ ref: SSHSessionRef) async {
		h.terminals.ensureSSHController(
			vm: "Debian", ref: ref, arguments: ["debian.machman"],
			profile: h.profiles.defaultProfile)
		_ = await eventually { h.terminals.sshController(vm: "Debian", ref: ref) != nil }
	}

	@Test func aRestoredTornSessionIsNotOpen() async {
		let h = await DesktopHarness.make()
		h.tornTabs.open.insert(TornTab(vm: "Debian", tab: .ssh(tornSession)))
		#expect(h.viewModel.openSSHSessions(vm: "Debian").isEmpty)
	}

	@Test func aLiveTornSessionStaysListed() async {
		let h = await DesktopHarness.make()
		await startSession(h, tornSession)
		h.tornTabs.open.insert(TornTab(vm: "Debian", tab: .ssh(tornSession)))
		#expect(h.viewModel.openSSHSessions(vm: "Debian") == [tornSession])
	}

	@Test func canvasAndTornSessionsAreBothListed() async {
		let h = await DesktopHarness.make()
		h.open(.ssh(canvasSession), vm: "Debian")
		await startSession(h, tornSession)
		h.tornTabs.open.insert(TornTab(vm: "Debian", tab: .ssh(tornSession)))
		h.tornTabs.open.insert(TornTab(vm: "Alpine", tab: .ssh(SSHSessionRef(title: "x"))))
		#expect(h.viewModel.openSSHSessions(vm: "Debian") == [canvasSession, tornSession])
	}

	// The tree numbered new sessions from the canvas alone, so a second "Session 1" opened
	// beside a torn one.
	@Test func newSessionNumbersSkipTornSessions() async {
		let h = await DesktopHarness.make()
		#expect(h.viewModel.nextSSHSessionTitle(vm: "Debian") == "Session 1")
		await startSession(h, tornSession)
		h.tornTabs.open.insert(TornTab(vm: "Debian", tab: .ssh(tornSession)))
		#expect(h.viewModel.nextSSHSessionTitle(vm: "Debian") == "Session 2")
		h.terminals.renameSSHSession(vm: "Debian", ref: tornSession, to: "Session 4")
		#expect(h.viewModel.nextSSHSessionTitle(vm: "Debian") == "Session 5")
	}
}
