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
