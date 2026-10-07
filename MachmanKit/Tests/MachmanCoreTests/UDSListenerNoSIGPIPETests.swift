//
//  UDSListenerNoSIGPIPETests.swift
//  MachmanCoreTests
//
//  E60, the server half: UDSConnection set SO_NOSIGPIPE on each accepted socket, which Darwin
//  refuses (EINVAL) once the client already hung up — a later write to that client then
//  raised SIGPIPE in the whole process (the agent ignores none). An accepted socket inherits
//  the option from its listener, so the listening socket carries it now, and every connection
//  has it from birth, whenever its client leaves.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanCore

private final class Accepted: @unchecked Sendable {
	private let lock = NSLock()
	private var fds: [Int32] = []
	private let arrived = DispatchSemaphore(value: 0)

	func add(_ fd: Int32) {
		lock.withLock { fds.append(fd) }
		arrived.signal()
	}

	func next(within seconds: Double) -> Int32? {
		guard arrived.wait(timeout: .now() + seconds) == .success else { return nil }
		return lock.withLock { fds.last }
	}

	func closeAll() {
		lock.withLock {
			for fd in fds { close(fd) }
			fds = []
		}
	}
}

struct UDSListenerNoSIGPIPETests {
	@Test("E60: a connection a listener accepts refuses SIGPIPE, even from a client that left")
	func anAcceptedConnectionRefusesSIGPIPE() throws {
		let path = TestEnvironment.socketPath("mm-nosigpipe")
		let accepted = Accepted()
		let listener = try UDSListener(
			path: path, queue: DispatchQueue(label: "mm-nosigpipe-accept")) { fd in
				accepted.add(fd)
			}
		defer {
			listener.shutdown()
			accepted.closeAll()
		}
		// A client that connects and hangs up before the server looks at its connection.
		var addr = try UDSListener.makeAddr(path)
		let client = socket(AF_UNIX, SOCK_STREAM, 0)
		try #require(client >= 0)
		let connected = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		close(client)
		try #require(connected)
		let fd = try #require(accepted.next(within: 10))
		var on: Int32 = 0
		var length = socklen_t(MemoryLayout<Int32>.size)
		#expect(getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, &length) == 0)
		#expect(on != 0)
	}
}
