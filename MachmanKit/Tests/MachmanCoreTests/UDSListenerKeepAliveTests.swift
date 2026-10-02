//
//  UDSListenerKeepAliveTests.swift
//  MachmanTests
//
//  E10: macOS's temp-dir cleaner deletes entries under $TMPDIR that went untouched for three
//  days, and connecting to a socket never refreshes its timestamps. A listener keeps its own
//  socket (and the socket's directory) fresh on a timer; the tests run that timer at 100 ms.
//

import Testing
import Foundation
import MachmanTestSupport
@testable import MachmanCore

struct UDSListenerKeepAliveTests {
	private func scratchDir() throws -> String {
		let dir = TestEnvironment.socketPath("mm-keep", suffix: "")
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		return dir
	}

	private func modified(_ path: String) -> Date {
		let attributes = try? FileManager.default.attributesOfItem(atPath: path)
		return attributes?[.modificationDate] as? Date ?? .distantPast
	}

	// Both times to 2020-01-01: what three idle days look like to the cleaner.
	private func age(_ path: String) {
		var times = [timeval(tv_sec: 1_577_836_800, tv_usec: 0),
			timeval(tv_sec: 1_577_836_800, tv_usec: 0)]
		_ = utimes(path, &times)
	}

	@Test @MainActor func aListenerKeepsItsSocketAndDirectoryFresh() async throws {
		let dir = try scratchDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let path = dir + "/l.sock"
		let listener = try UDSListener(
			path: path, queue: DispatchQueue(label: "mm-keep-accept"),
			keepAlive: .milliseconds(100)) { fd in close(fd) }
		defer { listener.shutdown() }
		age(path)
		age(dir)
		let old = Date(timeIntervalSince1970: 1_600_000_000)
		#expect(modified(path) < old)

		let recent = Date().addingTimeInterval(-60)
		#expect(await eventually { modified(path) > recent && modified(dir) > recent })
	}

	@Test @MainActor func shutdownStopsTheKeepAlive() async throws {
		let dir = try scratchDir()
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let path = dir + "/l.sock"
		let listener = try UDSListener(
			path: path, queue: DispatchQueue(label: "mm-keep-stop"),
			keepAlive: .milliseconds(100)) { fd in close(fd) }
		listener.shutdown()
		try await Task.sleep(for: .milliseconds(300))
		#expect(!FileManager.default.fileExists(atPath: path))   // never recreated by a touch
		#expect(!UDSListener.touch(path))                         // a missing socket reports it
	}
}
