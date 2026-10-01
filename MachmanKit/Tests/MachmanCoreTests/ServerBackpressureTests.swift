//
//  ServerBackpressureTests.swift
//  MachmanTests
//
//  E17: a client that subscribes to events and stops reading must be disconnected, not
//  buffered for without bound. Each connection's writes are bounded in time (no progress for
//  the send timeout) and in queued bytes. Raw sockets, so the test controls the reading.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
@testable import MachmanCore

struct ServerBackpressureTests {
	private func connect(_ path: String) -> Int32 {
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
		_ = withUnsafePointer(to: &addr) { p in
			p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		return fd
	}

	// Sends events.subscribe and reads its reply — after this the test never reads again.
	@MainActor
	private func subscribe(_ fd: Int32, _ stub: StubMachman) async -> Bool {
		let request = Array((#"{"jsonrpc":"2.0","id":1,"method":"events.subscribe"}"# + "\n").utf8)
		guard write(fd, request, request.count) == request.count else { return false }
		// Off the main actor: the server dispatches the request there.
		let reply = await Task.detached { () -> Data in
			var tv = timeval(tv_sec: 0, tv_usec: 100_000)
			setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
			var reply = Data()
			let deadline = Date().addingTimeInterval(3)
			while Date() < deadline, !reply.contains(UInt8(ascii: "\n")) {
				var buf = [UInt8](repeating: 0, count: 4096)
				let n = read(fd, &buf, buf.count)
				if n > 0 { reply.append(contentsOf: buf[0..<n]) } else if n == 0 { break }
			}
			return reply
		}.value
		guard String(decoding: reply, as: UTF8.self).contains(#""id":1"#) else { return false }
		// The reply goes out before the server's event pump has subscribed to the engine.
		return await eventually { stub.calls.contains("events") }
	}

	// Far more than the socket buffers hold (about 800 KB of event lines).
	@MainActor
	private func flood(_ stub: StubMachman) {
		let message = String(repeating: "x", count: 4096)
		for _ in 0..<200 {
			stub.emit(.log(vm: nil, level: .message, message: message))
		}
	}

	@MainActor
	private func makeServer() throws -> (MachmanServer, StubMachman, String) {
		// A write to a peer that is gone must fail with EPIPE, never kill the test runner.
		signal(SIGPIPE, SIG_IGN)
		let socketPath = TestEnvironment.scratch
			+ "mm-bp-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		return (server, stub, socketPath)
	}

	@Test @MainActor func aClientThatStopsReadingIsDropped() async throws {
		let (server, stub, socketPath) = try makeServer()
		defer { server.stop() }
		server.clientSendTimeout = 0.3
		let fd = connect(socketPath)
		defer { close(fd) }
		#expect(await subscribe(fd, stub))
		#expect(server.connectionCount == 1)

		flood(stub)
		#expect(await eventually(timeout: .seconds(5)) { server.connectionCount == 0 })
	}

	@Test @MainActor func aClientOverTheQueueCapIsDropped() async throws {
		let (server, stub, socketPath) = try makeServer()
		defer { server.stop() }
		server.clientSendTimeout = 30   // only the byte cap can end it within the wait below
		server.clientMaxQueuedBytes = 64 << 10
		let fd = connect(socketPath)
		defer { close(fd) }
		#expect(await subscribe(fd, stub))

		flood(stub)
		#expect(await eventually(timeout: .seconds(2)) { server.connectionCount == 0 })
	}
}
