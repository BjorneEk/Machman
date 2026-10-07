//
//  SerialRejoinTests.swift
//  MachmanDesktopUITests
//
//  E58: the console bridge closes a terminal that fell 1 MiB behind the guest's output and goes
//  on serving. The serial tab's controller then rejoins on its own and redraws from the bridge's
//  replay — cleared first, so nothing it showed shows twice — while a tab whose socket is gone
//  (the port stopped: the bridge unlinks first) keeps what it shows. Driven over a stand-in
//  socket on a thread of its own; the terminal is the real SwiftTerm one, read from its buffer.
//

import Foundation
import Testing
import MachmanUI
import MachmanTestSupport
@testable import MachmanDesktopUI

// A bridge stand-in: each accepted connection is sent its line, the first is closed, and
// `serving` says whether the socket stays to take the next one.
private final class StandInBridge: @unchecked Sendable {
	let path = TestEnvironment.socketPath("mm-rj", suffix: ".sock")
	private let listener: Int32

	init() throws {
		unlink(path)
		listener = socket(AF_UNIX, SOCK_STREAM, 0)
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
		let bound = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		guard bound == 0, listen(listener, 4) == 0 else {
			throw POSIXError(.EADDRINUSE)
		}
	}

	// Serves `lines` in order, one per connection; after the first it closes that connection,
	// first unlinking the socket (as a stopping bridge does) when `serving` is false. Only
	// stop() closes the listener.
	func serve(_ lines: [String], serving: Bool) {
		let listener = listener, path = path
		Thread.detachNewThread {
			var held: [Int32] = []
			for (n, line) in lines.enumerated() {
				let fd = accept(listener, nil, nil)
				guard fd >= 0 else { return }
				_ = line.utf8CString.withUnsafeBytes { write(fd, $0.baseAddress, line.utf8.count) }
				guard n == 0 else { held.append(fd); continue }
				Thread.sleep(forTimeInterval: 0.2)   // the terminal shows the line first
				if !serving { unlink(path) }
				close(fd)
				if !serving { return }
			}
			Thread.sleep(forTimeInterval: 10)
			held.forEach { close($0) }
		}
	}

	func stop() {
		close(listener)
		unlink(path)
	}
}

@MainActor
struct SerialRejoinTests {
	private func text(_ c: SerialTerminalController) -> String {
		String(decoding: c.terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
	}

	// A terminal on the stand-in's socket. The controller makes its terminal view at once, so
	// the host's app comes first: an NSView made before OffscreenHost.prepare() leaves a plain
	// NSApplication behind for every hosted test after it.
	private func terminal(on bridge: StandInBridge) async throws -> SerialTerminalController {
		try await OffscreenHost.exclusively {
			let c = SerialTerminalController(profile: TerminalProfile(name: "test"))
			c.connect(path: bridge.path)
			return c
		}
	}

	@Test("E58: a serial tab its bridge closed comes back on its own, redrawn from the replay")
	func aClosedTabRejoinsAndRedraws() async throws {
		let bridge = try StandInBridge()
		defer { bridge.stop() }
		bridge.serve(["FIRST-SCREEN\r\n", "REPLAYED\r\n"], serving: true)
		let c = try await terminal(on: bridge)
		#expect(await eventually { text(c).contains("REPLAYED") }, "\(text(c))")
		#expect(!text(c).contains("FIRST-SCREEN"), "the replay landed on the old screen")
		#expect(text(c).contains("reconnected after falling behind"))
		#expect(c.connected)
		c.disconnect()
	}

	@Test("E58: a serial tab whose socket is gone keeps what it shows")
	func aStoppedPortsTabKeepsItsScreen() async throws {
		let bridge = try StandInBridge()
		defer { bridge.stop() }
		bridge.serve(["LAST-SCREEN\r\n"], serving: false)
		let c = try await terminal(on: bridge)
		#expect(await eventually { !c.connected }, "\(text(c))")
		#expect(text(c).contains("LAST-SCREEN"))
		#expect(!text(c).contains("reconnected"))
	}
}
