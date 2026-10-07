//
//  RPCNoSIGPIPETests.swift
//  MachmanClientTests
//
//  RPCConnection set SO_NOSIGPIPE after connect(), and Darwin refuses that option (EINVAL) on
//  a socket whose peer already hung up: a client that connected to a host which accepted and
//  left at once (one exiting, one that never serves) was killed by SIGPIPE on its first write
//  — the agent's router, the desktop, the agent menu. The socket is set up before it connects
//  now. (Before, the race was too narrow for a test to win on purpose; a C probe showed the
//  EINVAL and the signal.)
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
@testable import MachmanClient

// Accepts every connection and hangs up at once. Its accept thread owns the listening
// descriptor and closes it itself on the way out, so no number is used after it is closed.
private final class HangUpHost: @unchecked Sendable {
	let socketPath: String
	private let lock = NSLock()
	private var stopping = false
	private let stopped = DispatchSemaphore(value: 0)

	init() throws {
		socketPath = TestEnvironment.socketPath("mm-hangup")
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard var addr = Self.address(socketPath) else {
			Darwin.close(fd)
			throw MachmanError(code: .internalError, message: "no address for \(socketPath)")
		}
		let bound = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		guard bound, listen(fd, 8) == 0 else {
			Darwin.close(fd)
			throw MachmanError(code: .internalError, message: "cannot bind \(socketPath)")
		}
		Thread.detachNewThread { [self] in
			while true {
				let conn = accept(fd, nil, nil)
				if conn >= 0 { Darwin.close(conn) }
				if lock.withLock({ stopping }) || conn < 0 { break }
			}
			Darwin.close(fd)
			stopped.signal()
		}
	}

	// Stops the accept thread with one last connect of its own, then removes the socket.
	func close() {
		lock.withLock { stopping = true }
		let waker = socket(AF_UNIX, SOCK_STREAM, 0)
		if var addr = Self.address(socketPath) {
			_ = withUnsafePointer(to: &addr) {
				$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
					connect(waker, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
				}
			}
		}
		_ = stopped.wait(timeout: .now() + 10)
		Darwin.close(waker)
		unlink(socketPath)
	}

	private static func address(_ path: String) -> sockaddr_un? {
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
		withUnsafeMutablePointer(to: &addr.sun_path) {
			$0.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
				_ = path.withCString { strlcpy(dst, $0, 104) }
			}
		}
		return addr
	}
}

struct RPCNoSIGPIPETests {
	private static func noSIGPIPE(_ fd: Int32) -> Bool {
		var on: Int32 = 0
		var length = socklen_t(MemoryLayout<Int32>.size)
		return getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, &length) == 0 && on != 0
	}

	@Test("E60: a connection's socket refuses SIGPIPE before it connects")
	func theSocketRefusesSIGPIPEBeforeItConnects() throws {
		let fd = RPCConnection.newSocket(sendTimeout: .seconds(1))
		try #require(fd >= 0)
		defer { close(fd) }
		#expect(Self.noSIGPIPE(fd))
	}

	@Test("E60: a host that hangs up at once fails the call and never raises SIGPIPE")
	func aHostThatHangsUpAtOnceFailsTheCall() async throws {
		let host = try HangUpHost()
		defer { host.close() }
		for _ in 0..<20 {
			let connection = try RPCConnection(socketPath: host.socketPath)
			// Checked before the write: without it the write below would kill the runner.
			try #require(Self.noSIGPIPE(connection.fdForTesting))
			do {
				_ = try await connection.call(
					.hello, RPCEmpty?.none, expecting: RPCEmpty.self, deadline: .seconds(5))
				Issue.record("a host that hung up answered")
			} catch {
				// Disconnected: the write failed with EPIPE, or the reader met the hang-up.
			}
			await connection.disconnect()
		}
	}
}
