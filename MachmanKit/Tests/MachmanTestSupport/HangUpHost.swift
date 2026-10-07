//
//  HangUpHost.swift
//  MachmanTestSupport
//
//  A unix-socket listener in the run's sandbox that accepts every connection and hangs up at
//  once: a vmhost exiting, a server stopping. A client that connects to it meets a peer that
//  already left — where Darwin refuses SO_NOSIGPIPE (EINVAL) and a write raises SIGPIPE in a
//  process that set it too late (E60).
//

import Foundation

// Its accept thread owns the listening descriptor and closes it itself on the way out, so no
// number is used after it is closed.
public final class HangUpHost: @unchecked Sendable {
	public let socketPath: String
	private let lock = NSLock()
	private var stopping = false
	private let stopped = DispatchSemaphore(value: 0)

	public init() throws {
		socketPath = TestEnvironment.socketPath("mm-hangup")
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard var addr = Self.address(socketPath) else {
			Darwin.close(fd)
			throw POSIXError(.ENAMETOOLONG)
		}
		let bound = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		guard bound, listen(fd, SOMAXCONN) == 0 else {
			Darwin.close(fd)
			throw POSIXError(.EADDRINUSE)
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
	public func close() {
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
