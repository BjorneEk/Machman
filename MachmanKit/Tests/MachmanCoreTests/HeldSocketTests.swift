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

	@Test func theHolderOfABoundSocketIsThisProcess() throws {
		let path = TestEnvironment.socketPath("mm-holder")
		#expect(UDSListener.holderPID(path: path) == nil)
		let listener = try UDSListener(path: path, queue: .global()) { fd in close(fd) }
		defer { listener.shutdown() }
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
