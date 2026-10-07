//
//  SerialTerminalConnectionTests.swift
//  MachmanUITests
//
//  The serial tabs' socket client against a test-owned unix socket standing in for the
//  vmhost's bridge (TerminalStreamSupport) — no daemon, no VM.
//

import Testing
import Foundation
@testable import MachmanUI
import MachmanTestSupport

@MainActor
struct SerialTerminalConnectionTests {

	@Test func bytesFlowBothWaysAndAHangUpEndsTheStream() async throws {
		let peer = try SocketPeer()
		defer { peer.close() }
		let stream = SerialTerminalConnection(path: peer.path)
		let sink = StreamSink()
		stream.onData = { sink.append($0) }
		stream.onClose = { sink.markClosed() }
		defer { stream.stop() }
		#expect(stream.connect())
		#expect(await eventually(timeout: .seconds(20)) { peer.client >= 0 })
		peer.startDraining(keep: true)
		stream.send(Data("ping".utf8))
		#expect(await eventually { peer.drainedData == Data("ping".utf8) })
		peer.write(Data("BYE".utf8))
		peer.hangUp()
		#expect(await eventually { sink.isClosed })
		#expect(sink.textWhenClosed == "BYE")
		#expect(stream.transcriptData() == Data("BYE".utf8))
	}

	// Q5: the transcript keeps the output's last 8 MiB and nothing more alive.
	@Test func theTranscriptKeepsOnlyItsLastEightMiB() async throws {
		let peer = try SocketPeer()
		defer { peer.close() }
		let stream = SerialTerminalConnection(path: peer.path)
		let sink = StreamSink()
		stream.onClose = { sink.markClosed() }
		defer { stream.stop() }
		#expect(stream.connect())
		#expect(await eventually(timeout: .seconds(20)) { peer.client >= 0 })
		let chunk = Data(repeating: 0, count: 1 << 20)
		Thread.detachNewThread {
			for _ in 0..<20 { peer.write(chunk) }
			peer.write(Data("END".utf8))
			peer.hangUp()
		}
		#expect(await eventually(timeout: .seconds(20)) { sink.isClosed })
		let transcript = stream.transcriptData()
		#expect(transcript.count == 8 << 20)
		#expect(transcript.startIndex == 0, "still holds \(transcript.startIndex) dead bytes")
		#expect(transcript.suffix(3) == Data("END".utf8))
	}

	// P5: a peer that stopped reading must not hold the caller in send().
	@Test func aStalledPeerNeverBlocksSend() async throws {
		let peer = try SocketPeer()
		defer { peer.close() }
		let stream = SerialTerminalConnection(path: peer.path)
		defer { stream.stop() }
		#expect(stream.connect())
		#expect(await eventually(timeout: .seconds(20)) { peer.client >= 0 })
		peer.startDraining(after: 2)
		let clock = ContinuousClock()
		let start = clock.now
		stream.send(Data(repeating: 0x61, count: 1 << 20))
		let elapsed = start.duration(to: clock.now)
		#expect(elapsed < .milliseconds(500), "send blocked for \(elapsed)")
		#expect(await eventually(timeout: .seconds(8)) { peer.drainedBytes == 1 << 20 })
	}

	// P5: what a stalled peer has not taken is held up to the cap; past it, input is dropped.
	@Test func inputPastTheCapIsDropped() async throws {
		let peer = try SocketPeer()
		defer { peer.close() }
		let stream = SerialTerminalConnection(path: peer.path)
		defer { stream.stop() }
		#expect(stream.connect())
		#expect(await eventually(timeout: .seconds(20)) { peer.client >= 0 })
		peer.startDraining(after: 0.5)   // armed first: a blocking send must not hang the test
		stream.send(Data(repeating: 0x61, count: 9 << 20))
		#expect(await eventually(timeout: .seconds(8)) { peer.drainedBytes >= 8 << 20 })
		try await Task.sleep(for: .milliseconds(300))
		#expect(peer.drainedBytes < (8 << 20) + (512 << 10), "got \(peer.drainedBytes)")
	}

	@Test func queuedInputArrivesInOrder() async throws {
		let peer = try SocketPeer()
		defer { peer.close() }
		let stream = SerialTerminalConnection(path: peer.path)
		defer { stream.stop() }
		#expect(stream.connect())
		#expect(await eventually(timeout: .seconds(20)) { peer.client >= 0 })
		peer.startDraining(after: 0.3, keep: true)
		let a = Data(repeating: UInt8(ascii: "A"), count: 100_000)
		let b = Data(repeating: UInt8(ascii: "B"), count: 100_000)
		stream.send(a)
		stream.send(b)
		for _ in 0..<1000 { stream.send(Data("c".utf8)) }
		#expect(await eventually(timeout: .seconds(8)) { peer.drainedBytes == 201_000 })
		#expect(peer.drainedData == a + b + Data(repeating: UInt8(ascii: "c"), count: 1000))
	}

	// A keystroke racing the vmhost's exit hits a hung-up socket: EPIPE, never SIGPIPE
	// (which would kill the desktop — it does not ignore the signal).
	@Test func theSocketNeverRaisesSIGPIPE() async throws {
		let peer = try SocketPeer()
		defer { peer.close() }
		let stream = SerialTerminalConnection(path: peer.path)
		defer { stream.stop() }
		#expect(stream.connect())
		let fd = try #require(stream.descriptor)
		var on: Int32 = 0
		var length = socklen_t(MemoryLayout<Int32>.size)
		#expect(getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, &length) == 0)
		#expect(on != 0)
	}

	// E60, the console's half (review F13): the socket refused SIGPIPE only after connect(),
	// and Darwin refuses that option (EINVAL) once the peer already hung up — a tab connecting,
	// or rejoining, while its vmhost's bridge goes away. Its first keystroke then raised
	// SIGPIPE, which kills the desktop.
	@Test("E60: a serial terminal's socket refuses SIGPIPE before it connects")
	func theSocketRefusesSIGPIPEBeforeItConnects() throws {
		let fd = SerialTerminalConnection.newSocket()
		try #require(fd >= 0)
		defer { close(fd) }
		#expect(Self.noSIGPIPE(fd))
	}

	@Test("E60: a bridge that hangs up at once never raises SIGPIPE in a serial terminal")
	func aBridgeThatHangsUpAtOnceNeverRaisesSIGPIPE() throws {
		let host = try HangUpHost()
		defer { host.close() }
		for _ in 0..<20 {
			let fd = try #require(SerialTerminalConnection.connectedSocket(path: host.socketPath))
			defer { close(fd) }
			// Checked before the write: without it the write below would kill the runner.
			try #require(Self.noSIGPIPE(fd))
			var key = UInt8(ascii: "k")
			_ = write(fd, &key, 1)   // EPIPE once the bridge has left
		}
	}

	private static func noSIGPIPE(_ fd: Int32) -> Bool {
		var on: Int32 = 0
		var length = socklen_t(MemoryLayout<Int32>.size)
		return getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, &length) == 0 && on != 0
	}

	// P6: the peer hangs up while the main thread keeps typing. Before the channel the
	// reader closed the socket under a running send (ThreadSanitizer: races in send() and
	// stop()), and the write into the hung-up socket raised SIGPIPE.
	@Test func typingThroughAHangUpIsSafe() async throws {
		for _ in 0..<20 {
			let peer = try SocketPeer()
			defer { peer.close() }
			let stream = SerialTerminalConnection(path: peer.path)
			let sink = StreamSink()
			stream.onClose = { sink.markClosed() }
			#expect(stream.connect())
			#expect(await eventually(timeout: .seconds(20)) { peer.client >= 0 })
			peer.startDraining()
			Thread.detachNewThread {
				peer.write(Data(repeating: 0x41, count: 4096))
				peer.hangUp()
			}
			for _ in 0..<200 where !sink.isClosed {
				stream.send(Data("k".utf8))
				await Task.yield()
			}
			stream.stop()
		}
	}

	// Input still queued for a stalled peer when it hangs up: the queue is dropped, the
	// write source stops, and the end is reported once.
	@Test func aHangUpWithInputStillQueuedEndsOnce() async throws {
		for _ in 0..<10 {
			let peer = try SocketPeer()
			defer { peer.close() }
			let stream = SerialTerminalConnection(path: peer.path)
			let sink = StreamSink()
			stream.onClose = { sink.markClosed() }
			defer { stream.stop() }
			#expect(stream.connect())
			#expect(await eventually(timeout: .seconds(20)) { peer.client >= 0 })
			stream.send(Data(repeating: 0x61, count: 1 << 20))   // the peer reads none of it
			try await Task.sleep(for: .milliseconds(50))
			peer.hangUp()
			#expect(await eventually { sink.isClosed })
			try await Task.sleep(for: .milliseconds(100))
			#expect(sink.closeCount == 1)
		}
	}

	@Test func stopIsSilentAndALaterSendGoesNowhere() async throws {
		let peer = try SocketPeer()
		defer { peer.close() }
		let stream = SerialTerminalConnection(path: peer.path)
		let sink = StreamSink()
		stream.onClose = { sink.markClosed() }
		#expect(stream.connect())
		#expect(await eventually(timeout: .seconds(20)) { peer.client >= 0 })
		peer.startDraining()
		stream.stop()
		stream.send(Data("late".utf8))
		try await Task.sleep(for: .milliseconds(200))
		#expect(!sink.isClosed)
		#expect(peer.drainedBytes == 0)
	}

	@Test func aMissingSocketFailsToConnect() {
		let stream = SerialTerminalConnection(path: TestEnvironment.scratch + "nobody.sock")
		#expect(!stream.connect())
		stream.send(Data("x".utf8))   // safe while unconnected
		stream.stop()
	}
}
