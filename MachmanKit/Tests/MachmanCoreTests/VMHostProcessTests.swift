//
//  VMHostProcessTests.swift
//  MachmanCoreTests
//
//  E61: a socket whose connects are refused is asked about from outside — does a live vmhost
//  still listen there, its accept queue full? This test process plays the vmhost (TestHook);
//  its listeners are read as a vmhost's are. No vmhost runs here.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanCore

struct VMHostProcessTests {
	@Test("E61: a socket file no vmhost listens on reads dead when it refuses")
	func aRefusingSocketNoVMHostServesReadsDead() {
		let path = TestEnvironment.socketPath("mm-dead")
		FileManager.default.createFile(atPath: path, contents: nil)   // a SIGKILL leftover
		defer { unlink(path) }
		#expect(VMHostProcess.serving(socketPath: path) == nil)
		#expect(!UDSListener.isLive(path: path))
		#expect(UDSListener.holderPID(path: path) == nil)
	}

	// Review F17: a vmhost counted as serving a path by its --socket argument alone. A run
	// saved as a new VM serves another path for the rest of its life, so a dead leftover at the
	// path it was launched on read live while it ran, and End Process there ended it — another
	// running VM. A process counts only while it holds a full listener bound for that path.
	@Test("E61: a socket file a live vmhost no longer listens on reads dead")
	func aSocketFileALiveVMHostNoLongerListensOnReadsDead() {
		let path = TestEnvironment.socketPath("mm-stale")
		FileManager.default.createFile(atPath: path, contents: nil)   // a crashed run's leftover
		defer { unlink(path) }
		VMHostProcess.TestHook.setServing(path, getpid())   // a live vmhost, listening elsewhere
		defer { VMHostProcess.TestHook.setServing(path, nil) }
		#expect(!UDSListener.isLive(path: path))
		#expect(UDSListener.holderPID(path: path) == nil)
		#expect(BoundSocket.removeIfDead(path) == .removed)
		#expect(!FileManager.default.fileExists(atPath: path))
	}

	@Test("E61: a frozen vmhost's full listener at a socket path reads live and stays")
	func aFrozenVMHostsFullListenerReadsLive() throws {
		let path = TestEnvironment.socketPath("mm-frozen")
		let host = try FrozenHost(path: path)
		defer { host.close() }
		VMHostProcess.TestHook.setServing(path, getpid())   // this process plays the vmhost
		defer { VMHostProcess.TestHook.setServing(path, nil) }
		#expect(host.fill() >= 1)   // its queue is full: every connect is refused now
		#expect(UDSListener.isLive(path: path))
		#expect(UDSListener.holderPID(path: path) == getpid())
		#expect(BoundSocket.removeIfDead(path) == .live)
		#expect(FileManager.default.fileExists(atPath: path))
	}

	// A vmhost's own listener is published from a staging name beside its path, and that is the
	// address the kernel keeps: the name has to say which path it serves.
	@Test("E61: a frozen vmhost's listener as published reads live once its queue is full")
	func aPublishedListenerReadsLiveOnceFull() throws {
		let path = TestEnvironment.socketPath("mm-published")
		let queue = DispatchQueue(label: "mm-published-accept")
		let listener = try UDSListener(path: path, queue: queue) { close($0) }
		VMHostProcess.TestHook.setServing(path, getpid())
		defer { VMHostProcess.TestHook.setServing(path, nil) }
		queue.suspend()   // frozen: nothing accepts any more
		defer {
			queue.resume()
			listener.shutdown()
		}
		#expect(FrozenHost.fill(path) > 0)
		#expect(UDSListener.isLive(path: path))
		#expect(UDSListener.holderPID(path: path) == getpid())
	}
}
