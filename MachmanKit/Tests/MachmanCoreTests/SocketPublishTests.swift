//
//  SocketPublishTests.swift
//  MachmanCoreTests
//
//  E48: a listener bound its socket at the served path and only then listened. A starter
//  probing the path in between had its connect refused, read the fresh socket as dead,
//  unlinked it and bound its own: two listeners "serving" one path, one of them unreachable.
//  A socket's path now appears only once it listens. And a listener closes its descriptor in
//  its source's cancel handler, as GCD asks; the race that rule prevents (a descriptor number
//  reused under a source still armed on it) shows at no tier, so its test pins the contract
//  around it: shutdown returns with the file gone, also from the middle of an accept.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanCore

struct SocketPublishTests {
	@Test("E48: of starters racing for one socket path, exactly one serves it")
	func ofStartersRacingForOnePathExactlyOneServesIt() async throws {
		let dir = TestEnvironment.socketPath("mm-race", suffix: "")
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: dir) }
		// The window is a few system calls wide, yet about one round in six hit it at base.
		let rounds = 500
		let starters = 4
		let doubled = await offPool { () -> Int in
			let queue = DispatchQueue(label: "mm-race-accept")
			var doubled = 0
			for round in 0..<rounds {
				let path = dir + "/r\(round % 50).sock"
				let lock = NSLock()
				var listeners: [UDSListener] = []
				DispatchQueue.concurrentPerform(iterations: starters) { _ in
					guard let listener = try? UDSListener(path: path, queue: queue, onAccept: {
						close($0)
					}) else { return }
					lock.withLock { listeners.append(listener) }
				}
				if listeners.count != 1 { doubled += 1 }
				listeners.forEach { $0.shutdown() }
			}
			return doubled
		}
		#expect(doubled == 0, "\(doubled) of \(rounds) rounds ended with other than one serving")
	}

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

	@Test("E48: shutdown returns with the socket file gone, even from the middle of an accept")
	func shutdownReturnsWithTheFileGoneEvenMidAccept() async throws {
		let path = TestEnvironment.socketPath("mm-cancel")
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		let listener = try UDSListener(
			path: path, queue: DispatchQueue(label: "mm-cancel-accept")
		) { fd in
			// The first accept holds; the release stays open for the probes accepted after it.
			entered.signal()
			release.wait()
			release.signal()
			close(fd)
		}
		let client = connect(path)
		defer { close(client) }
		await offPool { entered.wait() }
		let stopping = Task { await offPool { listener.shutdown() } }
		try await Task.sleep(for: .milliseconds(50))   // shutdown waits behind the accept
		#expect(UDSListener.isLive(path: path))
		release.signal()
		await stopping.value
		#expect(!FileManager.default.fileExists(atPath: path))
		#expect(!UDSListener.isLive(path: path))
	}
}
