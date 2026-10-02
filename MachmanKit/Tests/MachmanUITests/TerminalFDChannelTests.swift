//
//  TerminalFDChannelTests.swift
//  MachmanUITests
//
//  The transports' shared descriptor channel under a flood (P29): one end of a socket pair is
//  the channel's, the test writes into the other from its own thread, and the "main queue" is
//  a private queue the test can hold still. The test's end and its writer's dup are closed by
//  their owners only — never a number someone else may have reused.
//

import Testing
import Foundation
@testable import MachmanUI
import MachmanTestSupport

struct TerminalFDChannelTests {
	// The test's end of the pair; writes run on a detached thread through a dup it closes.
	final class Peer: @unchecked Sendable {
		let fd: Int32
		private let lock = NSLock()
		private var sent = 0
		private var hitEOF = false

		init(_ fd: Int32) {
			self.fd = fd
			var on: Int32 = 1
			_ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
		}

		var bytesSent: Int { lock.lock(); defer { lock.unlock() }; return sent }
		var sawEOF: Bool { lock.lock(); defer { lock.unlock() }; return hitEOF }

		// Writes `total` bytes counting 0, 1, 2… (mod 251) and then hangs up its write side.
		func flood(_ total: Int) {
			let out = dup(fd)
			Thread.detachNewThread { [self] in
				defer { Darwin.close(out) }
				var buf = [UInt8](repeating: 0, count: 64 << 10)
				var offset = 0
				while offset < total {
					let n = min(buf.count, total - offset)
					for i in 0..<n { buf[i] = UInt8((offset + i) % 251) }
					var done = 0
					while done < n {
						let w = buf.withUnsafeBytes { write(out, $0.baseAddress! + done, n - done) }
						if w > 0 { done += w; continue }
						if w < 0 && errno == EINTR { continue }
						return
					}
					offset += n
					lock.lock(); sent = offset; lock.unlock()
				}
				_ = shutdown(out, SHUT_WR)
			}
		}

		// Reads until EOF on a detached thread: the channel's end has closed.
		func watchForEOF() {
			let input = dup(fd)
			Thread.detachNewThread { [self] in
				defer { Darwin.close(input) }
				var buf = [UInt8](repeating: 0, count: 4096)
				while true {
					let n = read(input, &buf, buf.count)
					if n < 0 && errno == EINTR { continue }
					if n <= 0 { break }
				}
				lock.lock(); hitEOF = true; lock.unlock()
			}
		}
	}

	final class Counter: @unchecked Sendable {
		private let lock = NSLock()
		private var stored = -1
		func set(_ v: Int) { lock.lock(); stored = v; lock.unlock() }
		var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
	}

	private func pair() throws -> (channelEnd: Int32, peer: Peer) {
		var fds: [Int32] = [-1, -1]
		guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EMFILE) }
		return (fds[0], Peer(fds[1]))
	}

	// A held-up consumer pauses reading near the high-water mark instead of buffering the whole
	// flood, and once it runs again everything arrives in order, then the end, once.
	@Test func aBacklogPausesReadingAndEverythingStillArrives() async throws {
		let (end, peer) = try pair()
		defer { Darwin.close(peer.fd) }
		let delivery = DispatchQueue(label: "test.delivery")
		delivery.suspend()
		let channel = TerminalFDChannel(
			fd: end, label: "test", deliverOn: delivery, highWater: 256 << 10, lowWater: 64 << 10)
		let sink = StreamSink()
		let deliveredAtEnd = Counter()
		channel.start(
			onData: { sink.append($0) },
			onEnd: { deliveredAtEnd.set(sink.received.count); sink.markClosed() })
		let total = 4 << 20
		peer.flood(total)
		#expect(await eventually(timeout: .seconds(20)) { channel.isReadPaused })
		try await Task.sleep(for: .milliseconds(100))
		// Paused at the mark: the writer is stuck behind the socket's own buffer.
		#expect(channel.transcriptData().count <= (256 << 10) + (16 << 10))
		#expect(peer.bytesSent < total)
		delivery.resume()
		#expect(await eventually(timeout: .seconds(20)) { sink.isClosed })
		let received = sink.received
		#expect(received.count == total)
		#expect(received.enumerated().allSatisfy { $0.element == UInt8($0.offset % 251) })
		#expect(deliveredAtEnd.value == total)   // the end came after the last chunk
		try await Task.sleep(for: .milliseconds(100))
		#expect(sink.closeCount == 1)
		#expect(!channel.isReadPaused)
	}

	// Ending a paused channel still closes its descriptor: the peer sees the hang-up.
	@Test func closingAPausedChannelClosesItsDescriptor() async throws {
		let (end, peer) = try pair()
		defer { Darwin.close(peer.fd) }
		let delivery = DispatchQueue(label: "test.delivery")
		delivery.suspend()
		let channel = TerminalFDChannel(
			fd: end, label: "test", deliverOn: delivery, highWater: 64 << 10, lowWater: 16 << 10)
		let sink = StreamSink()
		channel.start(onData: { sink.append($0) }, onEnd: { sink.markClosed() })
		peer.flood(1 << 20)
		#expect(await eventually(timeout: .seconds(20)) { channel.isReadPaused })
		peer.watchForEOF()
		channel.close()
		#expect(await eventually(timeout: .seconds(20)) { peer.sawEOF })
		delivery.resume()
		try await Task.sleep(for: .milliseconds(100))
		#expect(!sink.isClosed)   // close() reports nothing
	}
}
