//
//  OffPool.swift
//  MachmanTestSupport
//
//  Blocking work in a test (a socket read loop) on a thread of its own while the caller
//  suspends. The cooperative pool has one thread per core, so a pool thread blocked in read()
//  for seconds starves every Task-based test beside it in the parallel suite (Subprocess's
//  lesson, wave 2).
//

import Foundation

public func offPool<T>(_ work: @escaping @Sendable () -> T) async -> T {
	await withCheckedContinuation { continuation in
		Thread.detachNewThread {
			continuation.resume(returning: work())
		}
	}
}

public enum SocketLines {
	// Newline-framed lines read from `fd` until `count` have arrived, the peer closed or
	// `timeout` passed: generous deadlines cost nothing, since the read returns as soon as
	// the lines are there.
	public static func read(_ fd: Int32, count: Int, timeout: TimeInterval) async -> [String] {
		await offPool {
			var tv = timeval(tv_sec: 0, tv_usec: 100_000)
			setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
			var received = Data()
			let deadline = Date().addingTimeInterval(timeout)
			while Date() < deadline, received.count(where: { $0 == UInt8(ascii: "\n") }) < count {
				var buffer = [UInt8](repeating: 0, count: 4096)
				let n = Darwin.read(fd, &buffer, buffer.count)
				if n > 0 {
					received.append(contentsOf: buffer[0..<n])
				} else if n == 0 {
					break
				}
			}
			return String(decoding: received, as: UTF8.self)
				.split(separator: "\n").map(String.init)
		}
	}
}
