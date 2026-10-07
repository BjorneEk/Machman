//
//  FrozenHost.swift
//  MachmanTestSupport
//
//  A unix socket in the run's sandbox that listens and never accepts: a frozen (SIGSTOPped)
//  vmhost. Each connect stays in its accept queue for good; once the queue is full a connect is
//  refused like a dead socket's (E61). Bound at the path itself.
//

import Foundation

public final class FrozenHost {
	private let fd: Int32
	private let path: String

	// A backlog of 1 fills at the first connect, as a vmhost's 128 do after about 40 lists.
	public init(path: String, backlog: Int32 = 1) throws {
		self.path = path
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
			throw POSIXError(.ENAMETOOLONG)
		}
		withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
		fd = socket(AF_UNIX, SOCK_STREAM, 0)
		let bound = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		guard bound, listen(fd, backlog) == 0 else {
			Darwin.close(fd)
			throw POSIXError(.EADDRINUSE)
		}
	}

	// Connects to `path` until a connect is refused, as the probes of clients that list a frozen
	// vmhost's VM do; the number that went through.
	@discardableResult
	public static func fill(_ path: String, upTo limit: Int = 400) -> Int {
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
		for count in 0..<limit {
			let probe = socket(AF_UNIX, SOCK_STREAM, 0)
			let connected = withUnsafePointer(to: &addr) {
				$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
					connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
				}
			}
			Darwin.close(probe)
			if !connected { return count }
		}
		return limit
	}

	@discardableResult
	public func fill() -> Int { Self.fill(path) }

	public func close() {
		Darwin.close(fd)
		unlink(path)
	}
}
