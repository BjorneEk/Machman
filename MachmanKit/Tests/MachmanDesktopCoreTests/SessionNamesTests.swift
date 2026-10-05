//
//  SessionNamesTests.swift
//  MachmanDesktopCoreTests
//
//  What a torn window and a new SSH session are called (T13): a torn ssh window's title
//  follows the session's renames, and a new "Session N" never repeats a name still showing
//  in any window — restored notice windows included.
//

import Testing
import Foundation
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct SessionNamesTests {
	private let session = SSHSessionRef(title: "Session 1")

	@Test func aTornSessionTitleFollowsRenames() async {
		let h = await DesktopHarness.make()
		let torn = TornTab(vm: "Debian", tab: .ssh(session))
		#expect(torn.windowTitle(vms: h.viewModel.vms, terminals: h.terminals)
			== "Debian — Session 1")
		h.terminals.renameSSHSession(vm: "Debian", ref: session, to: "Build")
		#expect(torn.windowTitle(vms: h.viewModel.vms, terminals: h.terminals)
			== "Debian — Build")
	}

	// A window the system restored after a relaunch holds no session, so it is not listed
	// (T20) — but its title still reads "Debian — Session 1", and a new session must not
	// open beside it under the same name.
	@Test func newSessionsNumberPastRestoredWindows() async {
		let h = await DesktopHarness.make()
		h.tornTabs.open.insert(TornTab(vm: "Debian", tab: .ssh(session)))
		h.tornTabs.open.insert(TornTab(vm: "Alpine", tab: .ssh(SSHSessionRef(title: "Session 6"))))
		#expect(h.viewModel.openSSHSessions(vm: "Debian").isEmpty)
		#expect(h.viewModel.nextSSHSessionTitle(vm: "Debian") == "Session 2")
	}

	@Test func aPortWindowNamesThePortForItsBootMode() async {
		let h = await DesktopHarness.make()
		let ref = SerialPortRef(kind: .console, index: 0)
		let torn = TornTab(vm: "Debian", tab: .terminal(ref))
		let port = h.viewModel.vms.first { $0.name == "Debian" }?.consolePorts?.first
		#expect(torn.windowTitle(vms: h.viewModel.vms, terminals: h.terminals)
			== "Debian — " + (port?.displayName(mode: .efi) ?? "?"))
		// Mid-reconnect (no list): the ref's own EFI name.
		#expect(torn.windowTitle(vms: nil, terminals: h.terminals) == "Debian — Console 0")
	}

	// W4: the preview tab tore off as “Debian — Configuration”; it shows the preview, and the
	// canvas tab strip names it by its VM alone.
	// Q12: the canvas tab and the torn window name a tab the same way, from one place.
	@Test func aTabIsNamedAsItsTornWindowNamesIt() async throws {
		let h = await DesktopHarness.make()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		let console = VMPaneTab.terminal(SerialPortRef(kind: .console, index: 0))
		h.terminals.renameSSHSession(vm: "Debian", ref: session, to: "Build")
		for tab in [VMPaneTab.config, console, .ssh(session)] {
			let title = tab.title(vm: "Debian", info: debian, sessions: h.terminals)
			let window = TornTab(vm: "Debian", tab: tab)
				.windowTitle(vms: h.viewModel.vms, terminals: h.terminals)
			#expect(window == (tab == .config ? title : "Debian — \(title)"))
		}
		#expect(console.title(vm: "Debian", info: debian, sessions: h.terminals) == "hvc0")
		#expect(console.symbol == MachmanSymbols.serialConsole)
	}

	@Test func aPreviewWindowIsTitledByItsVM() async {
		let h = await DesktopHarness.make()
		let torn = TornTab(vm: "Debian", tab: .config)
		#expect(torn.windowTitle(vms: h.viewModel.vms, terminals: h.terminals) == "Debian")
		#expect(torn.windowTitle(vms: nil, terminals: h.terminals) == "Debian")
	}
}
