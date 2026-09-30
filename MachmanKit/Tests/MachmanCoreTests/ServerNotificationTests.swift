//
//  ServerNotificationTests.swift
//  MachmanTests
//
//  JSON-RPC 2.0 notification handling (A11): a request without an id is a notification and is
//  never answered — including one naming an unknown method. Requests WITH an id keep getting
//  their method-not-found error. Exercised over a real socket with raw newline-framed writes
//  (RemoteMachman never sends notifications).
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

struct ServerNotificationTests {
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

	private func recvLines(_ fd: Int32, count: Int, timeout: Double) -> [String] {
		var acc = Data()
		var tv = timeval(tv_sec: 0, tv_usec: 100_000)
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline, acc.count(where: { $0 == UInt8(ascii: "\n") }) < count {
			var buf = [UInt8](repeating: 0, count: 4096)
			let n = read(fd, &buf, buf.count)
			if n > 0 { acc.append(contentsOf: buf[0..<n]) } else if n == 0 { break }
		}
		return String(decoding: acc, as: UTF8.self).split(separator: "\n").map(String.init)
	}

	@Test func notificationsAreNeverAnswered() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-notif-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let server = try await MainActor.run {
			let server = MachmanServer(
				api: StubMachman(), socketPath: socketPath, daemonVersion: "test")
			try server.start()
			return server
		}
		let fd = connect(socketPath)
		#expect(fd >= 0)

		// One write = one arrival order: two notifications (known and unknown method), then
		// two real requests. The main actor handles lines in order, so once the id:2 error
		// is here, both notifications were fully processed — a reply to either would have
		// arrived before it.
		let batch = [
			#"{"jsonrpc":"2.0","method":"vm.list"}"#,
			#"{"jsonrpc":"2.0","method":"no.such.method"}"#,
			#"{"jsonrpc":"2.0","id":1,"method":"machman.hello"}"#,
			#"{"jsonrpc":"2.0","id":2,"method":"no.such.method"}"#,
			"",
		].joined(separator: "\n")
		let bytes = Array(batch.utf8)
		#expect(write(fd, bytes, bytes.count) == bytes.count)

		let replies = recvLines(fd, count: 2, timeout: 3)
		#expect(replies.count == 2)
		#expect(replies.first?.contains(#""id":1"#) == true)
		#expect(replies.first?.contains(#""apiVersion""#) == true)
		#expect(replies.last?.contains(#""id":2"#) == true)
		#expect(replies.last?.contains("unknown method") == true)
		// Nothing trickles in late for the notifications.
		#expect(recvLines(fd, count: 1, timeout: 0.5).isEmpty)

		close(fd)
		await MainActor.run { server.stop() }
	}
}
