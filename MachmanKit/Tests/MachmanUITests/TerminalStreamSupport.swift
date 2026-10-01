//
//  TerminalStreamSupport.swift
//  MachmanUITests
//
//  Fixtures for the terminal transport tests: a thread-safe sink for a stream's callbacks,
//  and a unix-socket peer in the run's scratch dir that plays the vmhost's serial bridge — it
//  stalls until told to drain, writes and hangs up on command. Never a daemon socket.
//

import Foundation
import MachmanTestSupport

final class StreamSink: @unchecked Sendable {
	private let lock = NSLock()
	private var data = Data()
	private var closes = 0
	private var textAtClose = ""

	func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }

	// Records what had arrived when the end was reported, to pin "after the last output".
	func markClosed() {
		lock.lock()
		closes += 1
		textAtClose = String(decoding: data, as: UTF8.self)
		lock.unlock()
	}

	var received: Data { lock.lock(); defer { lock.unlock() }; return data }
	var text: String { String(decoding: received, as: UTF8.self) }
	var isClosed: Bool { closeCount > 0 }
	var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }
	var textWhenClosed: String { lock.lock(); defer { lock.unlock() }; return textAtClose }
}

// One listener, one accepted client. It reads only once told to drain.
final class SocketPeer: @unchecked Sendable {
	let path: String
	private let lock = NSLock()
	private var listenFD: Int32 = -1
	private var clientFD: Int32 = -1
	private var drained = 0
	private var kept = Data()

	init() throws {
		path = TestEnvironment.scratch + "tp-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutablePointer(to: &addr.sun_path) {
			$0.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
				_ = path.withCString { strlcpy(dst, $0, 104) }
			}
		}
		let bound = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
		guard bound, listen(fd, 4) == 0 else {
			Darwin.close(fd)
			throw POSIXError(.EADDRINUSE)
		}
		listenFD = fd
		Thread.detachNewThread { [weak self] in
			let client = accept(fd, nil, nil)
			guard client >= 0 else { return }
			// The peer's own writes must not raise SIGPIPE in the test runner either.
			var on: Int32 = 1
			_ = setsockopt(
				client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
			self?.setClient(client)
		}
	}

	private func setClient(_ fd: Int32) { lock.lock(); clientFD = fd; lock.unlock() }
	var client: Int32 { lock.lock(); defer { lock.unlock() }; return clientFD }
	var drainedBytes: Int { lock.lock(); defer { lock.unlock() }; return drained }
	var drainedData: Data { lock.lock(); defer { lock.unlock() }; return kept }

	// Reads (and counts, and with keep: stores) everything the stream sends, on a
	// background thread, starting after delay.
	func startDraining(after delay: TimeInterval = 0, keep: Bool = false) {
		Thread.detachNewThread { [weak self] in
			if delay > 0 { Thread.sleep(forTimeInterval: delay) }
			var buf = [UInt8](repeating: 0, count: 65536)
			while let self, self.client >= 0 {
				let n = read(self.client, &buf, buf.count)
				if n <= 0 { return }
				self.lock.lock()
				self.drained += n
				if keep { self.kept.append(contentsOf: buf[0..<n]) }
				self.lock.unlock()
			}
		}
	}

	func write(_ data: Data) {
		let fd = client
		data.withUnsafeBytes { raw in
			guard let base = raw.baseAddress else { return }
			var off = 0
			while off < data.count {
				let n = Darwin.write(fd, base + off, data.count - off)
				if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
			}
		}
	}

	func hangUp() {
		lock.lock()
		defer { lock.unlock() }
		if clientFD >= 0 { Darwin.close(clientFD); clientFD = -1 }
	}

	func close() {
		hangUp()
		lock.lock()
		defer { lock.unlock() }
		if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1; unlink(path) }
	}
}
