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

// One listener, one accepted client. It reads only once told to drain. No thread ever acts
// on a descriptor NUMBER it does not own: the parallel suite reuses a closed number at once
// (lowest free), and a thread still holding a stale one took another test's connection or
// bytes. So the accept happens on the caller's own poll of `client`, and every background
// read or write goes through a dup that its thread closes itself.
final class SocketPeer: @unchecked Sendable {
	let path: String
	private let lock = NSLock()
	private var listenFD: Int32 = -1
	private var clientFD: Int32 = -1
	private var accepting = true   // until the one connection arrives, or the peer hangs up
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
		guard bound, listen(fd, 4) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
			Darwin.close(fd)
			throw POSIXError(.EADDRINUSE)
		}
		listenFD = fd
	}

	// The accepted connection, or -1. Tests poll it with `eventually` after connecting; each
	// read accepts once, without blocking, until the connection has arrived.
	var client: Int32 {
		lock.lock()
		defer { lock.unlock() }
		if accepting, listenFD >= 0 {
			let fd = accept(listenFD, nil, nil)
			if fd >= 0 {
				accepting = false
				// Darwin hands the listener's O_NONBLOCK on to the accepted socket.
				_ = fcntl(fd, F_SETFL, 0)
				// The peer's own writes must not raise SIGPIPE in the test runner either.
				var on: Int32 = 1
				_ = setsockopt(
					fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
				clientFD = fd
			}
		}
		return clientFD
	}

	var drainedBytes: Int { lock.lock(); defer { lock.unlock() }; return drained }
	var drainedData: Data { lock.lock(); defer { lock.unlock() }; return kept }

	// A descriptor of the connection for one caller to use and close, or -1.
	private func borrowClient() -> Int32 {
		_ = client
		lock.lock()
		defer { lock.unlock() }
		return clientFD >= 0 ? dup(clientFD) : -1
	}

	// Reads (and counts, and with keep: stores) everything the stream sends, on a
	// background thread, starting after delay. A hang-up ends it.
	func startDraining(after delay: TimeInterval = 0, keep: Bool = false) {
		let fd = borrowClient()
		guard fd >= 0 else { return }
		Thread.detachNewThread { [weak self] in
			defer { Darwin.close(fd) }
			if delay > 0 { Thread.sleep(forTimeInterval: delay) }
			var buf = [UInt8](repeating: 0, count: 65536)
			while true {
				let n = read(fd, &buf, buf.count)
				if n < 0 && errno == EINTR { continue }
				guard n > 0, let self else { return }
				self.lock.lock()
				self.drained += n
				if keep { self.kept.append(contentsOf: buf[0..<n]) }
				self.lock.unlock()
			}
		}
	}

	func write(_ data: Data) {
		let fd = borrowClient()
		guard fd >= 0 else { return }
		defer { Darwin.close(fd) }
		data.withUnsafeBytes { raw in
			guard let base = raw.baseAddress else { return }
			var off = 0
			while off < data.count {
				let n = Darwin.write(fd, base + off, data.count - off)
				if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
			}
		}
	}

	// Ends the connection the way a vmhost's exit does: the stream reads EOF, and once the
	// peer's threads drop their dups (at once: shutdown wakes their reads and writes), its
	// writes fail with EPIPE. A plain close would leave the socket open through those dups.
	func hangUp() {
		lock.lock()
		defer { lock.unlock() }
		accepting = false
		if clientFD >= 0 {
			_ = Darwin.shutdown(clientFD, SHUT_RDWR)
			Darwin.close(clientFD)
			clientFD = -1
		}
	}

	func close() {
		hangUp()
		lock.lock()
		defer { lock.unlock() }
		if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1; unlink(path) }
	}
}
