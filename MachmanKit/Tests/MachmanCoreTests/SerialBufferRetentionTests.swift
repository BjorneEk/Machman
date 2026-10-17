//
//  SerialBufferRetentionTests.swift
//  MachmanTests
//
//  E31: the serial bridge's replay ring and guest-input queue drop bytes from the head.
//  Data.removeFirst only advances startIndex, so their storage kept every byte the VM ever
//  printed or was sent. The storage spans at least 0..<endIndex, which is what is bounded.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
@testable import MachmanCore

struct SerialBufferRetentionTests {
	private static let cap = 4096

	private static func chunk(_ n: Int, _ seed: Int) -> Data {
		Data((0..<n).map { UInt8(truncatingIfNeeded: seed &+ $0) })
	}

	// The replay ring: append, keep the last `cap` bytes.
	@Test func aRingKeepsItsTailAndItsStorageBounded() {
		var ring = Data()
		var all = Data()
		var peak = 0
		for i in 0..<500 {
			let piece = Self.chunk(700, i)
			ring.append(piece)
			all.append(piece)
			if ring.count > Self.cap { ring.dropHead(ring.count - Self.cap, live: Self.cap) }
			peak = max(peak, ring.endIndex)
		}
		#expect(peak <= 3 * Self.cap + 700)
		#expect(ring == all.suffix(Self.cap))
	}

	// The input queue: append what the pipe refused, drain what it took — FIFO, emptied often.
	@Test func aQueueKeepsItsOrderAndItsStorageBounded() {
		var queue = Data()
		var sent = Data()
		var received = Data()
		var peak = 0
		for i in 0..<2000 {
			let piece = Self.chunk(1 + i % 900, i)
			queue.append(piece)
			sent.append(piece)
			let taken = i % 7 == 0 ? queue.count : min(queue.count, 600)
			received.append(queue.prefix(taken))
			queue.dropHead(taken, live: Self.cap)
			peak = max(peak, queue.endIndex)
		}
		#expect(peak <= 3 * Self.cap + 900)
		received.append(queue)
		#expect(received == sent)
	}

	// End to end: 4 MiB of guest output through a bridge leaves a replay window, not a log.
	@Test @MainActor func aBridgeRetainsOnlyItsReplayWindow() async throws {
		let toGuest = Pipe()
		let fromGuest = Pipe()
		let base = TestEnvironment.socketPath("mm-ring", suffix: "")
		let bridge = SerialPortBridge(
			kind: .console, index: 0, socketPath: base + ".sock",
			logURL: URL(fileURLWithPath: base + ".log"),
			logConfig: SerialLogConfig(mode: .disabled), toGuest: toGuest.fileHandleForWriting,
			fromGuest: fromGuest.fileHandleForReading)
		bridge.start()
		defer { bridge.stop() }
		let guestOut = fromGuest.fileHandleForWriting
		let output = await onOwnThread { Self.chunk(4 << 20, 7) }   // off the main actor (Q43)
		// A blocking pipe write, off the main actor: it returns once the drain took all but
		// the pipe's own buffer.
		await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
			DispatchQueue.global().async {
				guestOut.write(output)
				done.resume()
			}
		}
		let replayCap = 256 * 1024
		#expect(bridge.retainedForTesting.ring <= 3 * replayCap + 16 * 1024)
		_ = toGuest
	}
}
