//
//  RPCConnectionLifetimeTests.swift
//  MachmanTests
//
//  E26: the reader thread holds the raw descriptor number for as long as it runs. Teardown
//  must never close that number under it — the next open() anywhere in the process reuses it
//  at once, and the reader's next read() would steal that file's or socket's bytes. Teardown
//  shuts the socket down; whichever side finishes second closes it.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
@testable import MachmanClient

// Accepts one connection; the test writes lines to it and closes it when it wants.
private final class LinePeer: @unchecked Sendable {
	let socketPath: String
	private let lock = NSLock()
	private var listenFD: Int32 = -1
	private var connFD: Int32 = -1
	private let accepted = DispatchSemaphore(value: 0)

	init() throws {
		socketPath = TestEnvironment.scratch
			+ "mm-line-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutablePointer(to: &addr.sun_path) {
			$0.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
				_ = socketPath.withCString { strlcpy(dst, $0, 104) }
			}
		}
		let bound = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		guard bound, listen(fd, 4) == 0 else {
			Darwin.close(fd)
			throw MachmanError(code: .internalError, message: "cannot bind \(socketPath)")
		}
		listenFD = fd
		Thread.detachNewThread { [weak self] in
			let conn = accept(fd, nil, nil)
			guard conn >= 0 else { return }
			self?.setConn(conn)
		}
	}

	private func setConn(_ fd: Int32) {
		lock.lock(); connFD = fd; lock.unlock()
		accepted.signal()
	}

	func send(line: String) {
		_ = accepted.wait(timeout: .now() + 5)
		accepted.signal()
		lock.lock()
		let fd = connFD
		lock.unlock()
		guard fd >= 0 else { return }
		_ = (line + "\n").withCString { write(fd, $0, strlen($0)) }
	}

	// Idempotent: every descriptor closes once.
	func close() {
		lock.lock()
		defer { lock.unlock() }
		if connFD >= 0 { Darwin.close(connFD); connFD = -1 }
		if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1; unlink(socketPath) }
	}
}

// Parks the reader thread after its first chunk until the test opens the gate.
private final class ReaderGate: @unchecked Sendable {
	let paused = DispatchSemaphore(value: 0)
	let gate = DispatchSemaphore(value: 0)
	private let lock = NSLock()
	private var used = false

	func hook() {
		lock.lock()
		let first = !used
		used = true
		lock.unlock()
		guard first else { return }
		paused.signal()
		_ = gate.wait(timeout: .now() + 10)
	}
}

private final class DisconnectCounter: @unchecked Sendable {
	private let lock = NSLock()
	private var value = 0
	func increment() { lock.lock(); value += 1; lock.unlock() }
	var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

struct RPCConnectionLifetimeTests {
	@Test func teardownNeverFreesTheNumberUnderTheReader() async throws {
		let peer = try LinePeer()
		defer { peer.close() }
		let reader = ReaderGate()
		let connection = try RPCConnection(
			socketPath: peer.socketPath, sendTimeout: RPCConnection.defaultSendTimeout,
			readerHook: { reader.hook() }, onDisconnect: {})

		peer.send(line: #"{"jsonrpc":"2.0","method":"event"}"#)
		let paused = await Task.detached { reader.paused.wait(timeout: .now() + 5) }.value
		#expect(paused == .success)

		// The reader sits between reads, holding the number: teardown must leave it open.
		await connection.disconnect()
		#expect(fcntl(connection.fdForTesting, F_GETFD) != -1)

		// Once the reader leaves its loop it closes the descriptor itself.
		reader.gate.signal()
		#expect(await eventually { connection.socketClosedForTesting })
	}

	@Test func peerCloseStillClosesOnce() async throws {
		let peer = try LinePeer()
		defer { peer.close() }
		let disconnects = DisconnectCounter()
		let connection = try RPCConnection(socketPath: peer.socketPath) {
			disconnects.increment()
		}

		peer.send(line: #"{"jsonrpc":"2.0","method":"event"}"#)
		peer.close()
		#expect(await eventually { disconnects.count == 1 && connection.socketClosedForTesting })
		await connection.disconnect()   // a later disconnect changes nothing
		try await Task.sleep(for: .milliseconds(50))
		#expect(disconnects.count == 1)
	}
}
