//
//  HeldSocketTests.swift
//  MachmanTests
//
//  Q7: the floor test once found its fresh socket path already served (1 in 25 full runs).
//  Test sockets are named by UUID now, and a server that finds its path taken says who
//  holds it: the holder's pid (LOCAL_PEERPID), the file's inode and birth, and the scratch
//  entries that share its prefix.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

struct HeldSocketTests {
	@Test func socketPathsAreFreshAndFitSunPath() throws {
		let first = TestEnvironment.socketPath("mm-x")
		let second = TestEnvironment.socketPath("mm-x")
		#expect(first != second)
		for path in [first, second] {
			#expect(path.utf8.count <= 103, "\(path)")
			#expect(path.hasPrefix(TestEnvironment.scratch + "mm-x-"))
			#expect(path.hasSuffix(".sock"))
			_ = try UDSListener.makeAddr(path)
		}
	}

	// The holder keeps what it accepts, as every real server does until its peer leaves (Q17):
	// LOCAL_PEERPID answers only while the probe's connection stands, and a holder that hung up
	// at once beat the ask under load — the lookup read nil.
	@Test func theHolderOfABoundSocketIsThisProcess() throws {
		let path = TestEnvironment.socketPath("mm-holder")
		#expect(UDSListener.holderPID(path: path) == nil)
		let kept = KeptConnections()
		let listener = try UDSListener(path: path, queue: .global()) { fd in kept.keep(fd) }
		defer {
			listener.shutdown()
			kept.closeAll()
		}
		#expect(UDSListener.holderPID(path: path) == getpid())
	}

	@Test @MainActor func aServedPathSaysWhoHoldsIt() throws {
		let path = TestEnvironment.socketPath("mm-held")
		let first = MachmanServer(api: StubMachman(), socketPath: path, daemonVersion: "test")
		try startServing(first)
		defer { first.stop() }

		let second = MachmanServer(api: StubMachman(), socketPath: path, daemonVersion: "test")
		do {
			try startServing(second)
			second.stop()
			Issue.record("expected the second server to find the path served")
		} catch let held as HeldSocket {
			#expect(held.description.contains("pid \(getpid())"))
			#expect(held.description.contains("this test process: yes"))
			#expect(held.description.contains("inode "))
			#expect(held.siblings == [(path as NSString).lastPathComponent])
		}
	}
}

// Accepted descriptors, held until the test is done with the listener.
private final class KeptConnections: @unchecked Sendable {
	private let lock = NSLock()
	private var fds: [Int32] = []

	func keep(_ fd: Int32) {
		lock.withLock { fds.append(fd) }
	}

	func closeAll() {
		lock.withLock {
			for fd in fds { close(fd) }
			fds.removeAll()
		}
	}
}
