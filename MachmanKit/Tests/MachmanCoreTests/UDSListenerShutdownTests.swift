//
//  UDSListenerShutdownTests.swift
//  MachmanTests
//
//  E44: a listener's shutdown closed its socket and only then unlinked the path. A successor
//  probing in between (the agent's takeover polls every 200 ms) read the socket dead, unlinked
//  it and bound its own — and the old listener's unlink then removed that fresh file, leaving
//  the new agent serving a socket nobody could reach. Shutdown now removes only the file it
//  bound, before it closes. And a bound socket keeps the full backlog: with listen(fd, 8) the
//  ninth waiting connect was refused, which isLive reads as a dead socket.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanCore

struct UDSListenerShutdownTests {
	private func listener(_ path: String, _ label: String) throws -> UDSListener {
		try UDSListener(path: path, queue: DispatchQueue(label: label)) { fd in close(fd) }
	}

	// A connected client descriptor, or nil when the connect was refused.
	private func connectClient(_ path: String) throws -> Int32? {
		var addr = try UDSListener.makeAddr(path)
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { return nil }
		let connected = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		guard connected else {
			close(fd)
			return nil
		}
		return fd
	}

	@Test func aShutdownRemovesItsOwnSocket() throws {
		let path = TestEnvironment.socketPath("mm-own")
		let own = try listener(path, "mm-own")
		#expect(UDSListener.isLive(path: path))
		own.shutdown()
		#expect(!FileManager.default.fileExists(atPath: path))
	}

	@Test func aShutdownLeavesASuccessorsSocket() throws {
		let path = TestEnvironment.socketPath("mm-succ")
		let old = try listener(path, "mm-succ-old")
		// What a successor does to a socket it read as dead: unlink it and bind its own.
		unlink(path)
		let successor = try listener(path, "mm-succ-new")
		defer { successor.shutdown() }
		old.shutdown()
		#expect(UDSListener.isLive(path: path))   // before: the old listener's unlink removed it
	}

	// The file keeps its identity across a rename (Save as New VM), so the new path goes.
	@Test func aMovedListenerRemovesItsNewPath() throws {
		let path = TestEnvironment.socketPath("mm-mvfrom")
		let moved = TestEnvironment.socketPath("mm-mvto")
		let served = try listener(path, "mm-mv")
		try served.move(to: moved)
		served.shutdown()
		#expect(!FileManager.default.fileExists(atPath: moved))
		#expect(!FileManager.default.fileExists(atPath: path))
	}

	@Test func aBoundSocketTakesAFullBacklog() throws {
		let path = TestEnvironment.socketPath("mm-backlog")
		let bound = try BoundSocket.listen(at: path)
		var clients: [Int32] = []
		defer {
			for fd in clients { close(fd) }
			bound.unlinkIfOurs(path)
			close(bound.fd)
		}
		// Nobody accepts, so every connect waits in the backlog.
		for _ in 0..<20 {
			guard let fd = try connectClient(path) else { break }
			clients.append(fd)
		}
		#expect(clients.count == 20)
		#expect(UDSListener.isLive(path: path))
	}
}
