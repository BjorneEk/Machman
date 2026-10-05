//
//  TerminalSurfaceTests.swift
//  MachmanDesktopUITests
//
//  What a terminal tab says when it has no live terminal, from the real tab views hosted
//  offscreen: a restored torn SSH window's session ended with the app (T5a), a disabled port
//  and a gated UART say why their tab is empty (W3-49, T10), and a serial tab already dead
//  past its grace says Disconnected. soon after it remounts (R3W1-10, T25). No ssh is ever
//  started (adopt-only), and the one socket touched is a sample path no process can create.
//

import SwiftUI
import Testing
import MachmanAPI
import MachmanUI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore
@testable import MachmanDesktopUI

// L1: desktop views hosted offscreen, read through in-process accessibility.
@MainActor
struct TerminalSurfaceTests {
	private func tab(_ h: UIHarness, _ vm: String, _ ref: SerialPortRef) async throws
		-> AXSnapshot {
		try await h.snapshot(
			TerminalTabContent(
				sessions: h.terminals, profiles: h.profiles, vm: h.vm(vm), ref: ref,
				stillWanted: { true }),
			width: 480, height: 320)
	}

	@Test("T5a: a restored torn SSH window says its session ended")
	func aRestoredSessionSaysItEnded() async throws {
		let h = await UIHarness.make([Samples.linux("Debian", state: .running)])
		let ref = SSHSessionRef(title: "Session 1")
		// A torn window adopts; it never starts a session (no ssh can spawn here).
		let tree = try await h.snapshot(
			SSHTabContent(
				sessions: h.terminals, viewModel: h.viewModel, profiles: h.profiles,
				vm: h.vm("Debian"), ref: ref, stillWanted: { true }, adoptOnly: true),
			width: 480, height: 320)
		#expect(tree.find(
			text: "This session ended \u{2014} sessions do not survive quitting Machman.") != nil,
			"\(tree.dump())")
		#expect(tree.find(text: "Open a new one from the SSH section in the sidebar.") != nil)
		#expect(h.terminals.sshTerminal(vm: "Debian", ref: ref) == nil)
	}

	@Test("W3-49: a disabled port and a gated UART say why their tab is empty")
	func emptyTabsSayWhy() async throws {
		let h = await UIHarness.make([Samples.disabledConsole(), Samples.gatedUART()])
		let console = SerialPortRef(kind: .console, index: 0)
		let consoleName = try #require(h.vm("Debian").port(for: console))
			.displayName(mode: .efi)
		let disabled = try await tab(h, "Debian", console)
		#expect(disabled.find(text: "Enable \(consoleName) and restart the VM to open it.")
			!= nil, "\(disabled.dump())")

		let uart = SerialPortRef(kind: .uart, index: 0)
		let port = try #require(h.vm("Kernel Lab").port(for: uart))
		let reason = try #require(port.unavailable?.message)
		let gated = try await tab(h, "Kernel Lab", uart)
		let name = port.displayName(mode: .linuxKernel)
		#expect(name == "ttyAMA0")
		let sentence = try #require(
			gated.find(text: "\(name) isn\u{2019}t available on this Mac."), "\(gated.dump())")
		#expect(gated.all.contains { $0.help == reason } || sentence.help == reason,
			"the tab's tooltip isn't the daemon's reason")
		// Neither tab made a terminal.
		#expect(h.terminals.serialTerminal(vm: "Debian", ref: console) == nil)
		#expect(h.terminals.serialTerminal(vm: "Kernel Lab", ref: uart) == nil)
	}

	@Test("R3W1-10: a tab dead past its grace shows Disconnected. soon after remount")
	func aDeadTabSaysSoSoonAfterRemount() async throws {
		let h = await UIHarness.make([Samples.linux("Debian", state: .running)])
		let ref = SerialPortRef(kind: .console, index: 0)
		// No process can create a socket under /var/empty: the connect fails with ENOENT. The
		// controller makes its terminal view at once, so the host's app comes first: an
		// NSView made before OffscreenHost.prepare() leaves a plain NSApplication behind.
		try await OffscreenHost.exclusively {
			h.terminals.ensureController(
				vm: "Debian", ref: ref, socketPath: "\(Samples.sockets)/none.sock",
				profile: h.profiles.defaultProfile)
		}
		#expect(await eventually {
			h.terminals.serialTerminal(vm: "Debian", ref: ref)?.disconnectedAt != nil
		})
		let controller = try #require(h.terminals.serialTerminal(vm: "Debian", ref: ref))
		#expect(!controller.connected)
		// Dead longer than its grace before this view mounts (a tear-off, a tab switch back).
		let grace = Duration.seconds(3)
		try await Task.sleep(for: grace + .milliseconds(500))
		try await OffscreenHost.withHost(
			SerialSessionSurface(
				controller: controller, vmIsStopping: false, grace: grace, reconnect: {}),
			width: 480, height: 320
		) { hosted in
			let clock = ContinuousClock()
			let mounted = clock.now
			// A grace counted from the mount would take its full 3 s; this is bounded at 2.
			let shown = await eventually(timeout: .seconds(2)) {
				hosted.snapshot().find(text: "Disconnected.") != nil
			}
			#expect(shown, "no Disconnected. within 2 s of the remount")
			#expect(clock.now - mounted < grace)
		}
	}
}
