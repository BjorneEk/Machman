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

// A bridge stand-in, serving connections in order by `plan`; past the plan, with `churn`, it
// closes every new connection at once. `serving` false unlinks the socket (as a stopping
// bridge does) before the first close. `accepted` counts connections.
private final class StandInBridge: @unchecked Sendable {
	enum Reply {
		case send(String)            // and keep the connection
		case sendThenClose(String)   // once the terminal has had a moment to show it
		case close                   // at once, nothing sent
	}

	let path = TestEnvironment.socketPath("mm-rj", suffix: ".sock")
	private let listener: Int32
	private let lock = NSLock()
	private var count = 0

	var accepted: Int { lock.withLock { count } }

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

	// Only stop() closes the listener.
	func serve(_ plan: [Reply], serving: Bool = true, churn: Bool = false) {
		let listener = listener, path = path
		Thread.detachNewThread { [self] in
			var held: [Int32] = []
			var step = 0
			while step < plan.count || churn {
				let fd = accept(listener, nil, nil)
				guard fd >= 0 else { break }
				lock.withLock { count += 1 }
				let reply = step < plan.count ? plan[step] : .close
				step += 1
				switch reply {
				case .send(let line):
					write(fd, line)
					held.append(fd)
				case .sendThenClose(let line):
					write(fd, line)
					Thread.sleep(forTimeInterval: 0.2)
					if !serving { unlink(path) }
					close(fd)
					if !serving { return }
				case .close:
					close(fd)
				}
			}
			Thread.sleep(forTimeInterval: 10)
			held.forEach { close($0) }
		}
	}

	private func write(_ fd: Int32, _ line: String) {
		_ = line.utf8CString.withUnsafeBytes {
			Darwin.write(fd, $0.baseAddress, line.utf8.count)
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
		bridge.serve([.sendThenClose("FIRST-SCREEN\r\n"), .send("REPLAYED\r\n")])
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
		bridge.serve([.sendThenClose("LAST-SCREEN\r\n")], serving: false)
		let c = try await terminal(on: bridge)
		#expect(await eventually { !c.connected }, "\(text(c))")
		#expect(text(c).contains("LAST-SCREEN"))
		#expect(!text(c).contains("reconnected"))
	}

	// Review F3: a connect alone proves little — a crashed vmhost's listener can take one
	// during its exit. A rejoin that gets no replay leaves the screen and Save Terminal's
	// transcript as they were, without the marker, and the tab offers Reconnect.
	@Test("E58: a tab whose rejoin gets no replay keeps its screen")
	func aRejoinWithoutReplayKeepsTheScreen() async throws {
		let bridge = try StandInBridge()
		defer { bridge.stop() }
		bridge.serve([.sendThenClose("PANIC-SCREEN\r\n"), .close])
		let c = try await terminal(on: bridge)
		#expect(await eventually { !c.connected && bridge.accepted == 2 }, "\(text(c))")
		#expect(text(c).contains("PANIC-SCREEN"))
		#expect(!text(c).contains("reconnected"))
		#expect(String(decoding: c.transcript(), as: UTF8.self).contains("PANIC-SCREEN"))
	}

	// …and a socket that takes a connection and closes it at once gets one automatic rejoin,
	// not a loop of them.
	@Test("E58: a socket that keeps closing at once gets one automatic rejoin")
	func rejoinsAreBounded() async throws {
		let bridge = try StandInBridge()
		defer { bridge.stop() }
		bridge.serve([.sendThenClose("SCREEN\r\n")], churn: true)
		let c = try await terminal(on: bridge)
		#expect(await eventually { !c.connected && bridge.accepted >= 2 })
		try await Task.sleep(for: .milliseconds(500))
		#expect(bridge.accepted == 2, "\(bridge.accepted) connections")
		#expect(text(c).contains("SCREEN"))
	}
}
