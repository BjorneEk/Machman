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

	// A dead leftover at `path`, as SIGKILL leaves one: bound, never listening, closed.
	private func plantDeadSocket(_ path: String) {
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
		_ = withUnsafePointer(to: &addr) { p in
			p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		close(fd)
	}

	private final class SecondStarter: @unchecked Sendable {
		let lock = NSLock()
		let finished = DispatchGroup()
		var listener: UDSListener?
		var started = false
	}

	// Review F1 (wave r3w3): a starter probed a dead leftover, and another starter unlinked it
	// and published its own live socket before the first unlinked — the first then removed
	// that live file and published too: two "serving", one unreachable. Starters of one path
	// take turns now. The hook stops the first starter between its probe and its unlink and
	// runs a second starter to the end there (it can't, now: it waits its turn).
	@Test("E48: a starter never unlinks a socket another one published after its probe")
	func aStarterNeverUnlinksASocketPublishedAfterItsProbe() async throws {
		let dir = TestEnvironment.socketPath("mm-left", suffix: "")
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let path = dir + "/s.sock"
		plantDeadSocket(path)
		#expect(FileManager.default.fileExists(atPath: path) && !UDSListener.isLive(path: path))
		let queue = DispatchQueue(label: "mm-left-accept")
		let second = SecondStarter()
		SocketStartHooks.setLeftoverProbed(path) {
			let first = second.lock.withLock { () -> Bool in
				defer { second.started = true }
				return !second.started
			}
			guard first else { return }
			second.finished.enter()
			Thread.detachNewThread {
				let listener = try? UDSListener(path: path, queue: queue, onAccept: { close($0) })
				second.lock.withLock { second.listener = listener }
				second.finished.leave()
			}
			// Before the fix the second starter is done well within this; now it waits.
			_ = second.finished.wait(timeout: .now() + .seconds(1))
		}
		defer { SocketStartHooks.setLeftoverProbed(path, nil) }
		let first = await offPool {
			try? UDSListener(path: path, queue: queue, onAccept: { close($0) })
		}
		await offPool { second.finished.wait() }
		let serving = [first, second.lock.withLock { second.listener }].compactMap { $0 }
		#expect(second.lock.withLock { second.started })
		#expect(serving.count == 1, "\(serving.count) starters serve one path")
		#expect(UDSListener.isLive(path: path))
		serving.forEach { $0.shutdown() }
	}

	// Review F13 (wave r3w3): the agent's own sweep probed a dead vm-*.sock and unlinked it
	// outside the starters' turn, so a vmhost that cleared the leftover and published its
	// live socket in between lost its socket file — running, unreachable. The sweep takes
	// the turn now. The hook stops it between its probe and its unlink and starts a vmhost's
	// listener on the path there (it can't publish now: it waits its turn).
	@Test("E48: the agent's sweep never removes a socket a vmhost published after its probe")
	func theSweepNeverRemovesASocketPublishedAfterItsProbe() async throws {
		let dir = TestEnvironment.socketPath("mm-sweep", suffix: "")
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let path = dir + "/vm-race0000.sock"
		plantDeadSocket(path)
		let queue = DispatchQueue(label: "mm-sweep-accept")
		let starter = SecondStarter()
		SocketStartHooks.setLeftoverProbed(path) {
			let first = starter.lock.withLock { () -> Bool in
				defer { starter.started = true }
				return !starter.started
			}
			guard first else { return }
			starter.finished.enter()
			Thread.detachNewThread {
				let listener = try? UDSListener(path: path, queue: queue, onAccept: { close($0) })
				starter.lock.withLock { starter.listener = listener }
				starter.finished.leave()
			}
			// Before the fix the vmhost has published well within this; now it waits.
			_ = starter.finished.wait(timeout: .now() + .seconds(1))
		}
		defer { SocketStartHooks.setLeftoverProbed(path, nil) }
		await offPool { RoutingMachman.pruneDeadHostSockets(in: dir) }
		await offPool { starter.finished.wait() }
		let listener = starter.lock.withLock { starter.listener }
		#expect(starter.lock.withLock { starter.started })
		#expect(listener != nil)
		#expect(FileManager.default.fileExists(atPath: path), "the sweep removed a live socket")
		#expect(UDSListener.isLive(path: path))
		listener?.shutdown()
	}
}
