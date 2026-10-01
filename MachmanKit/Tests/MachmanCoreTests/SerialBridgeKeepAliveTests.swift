//
//  SerialBridgeKeepAliveTests.swift
//  MachmanTests
//
//  E30: a serial port's data-plane socket (tty-*.sock) is bound by its bridge, outside
//  UDSListener, and gets the same keep-alive against the temp cleaner as the control
//  sockets (E10). The tests run the timer at 100 ms over bare pipes (no VZ).
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
@testable import MachmanCore

struct SerialBridgeKeepAliveTests {
	private struct Bridge {
		let bridge: SerialPortBridge
		let handles: [FileHandle]   // the guest ends, kept open for the bridge's lifetime
		var socketPath: String { bridge.socketPath }
	}

	private func makeBridge(_ tag: String, socketPath: String? = nil) -> Bridge {
		let toGuest = Pipe()
		let fromGuest = Pipe()
		let base = TestEnvironment.scratch
			+ "mm-\(tag)-\(getpid())-\(UInt32.random(in: 0..<99999))"
		let bridge = SerialPortBridge(
			kind: .console, index: 0, socketPath: socketPath ?? base + ".sock",
			logURL: URL(fileURLWithPath: base + ".log"),
			logConfig: SerialLogConfig(mode: .disabled), toGuest: toGuest.fileHandleForWriting,
			fromGuest: fromGuest.fileHandleForReading, keepAlive: .milliseconds(100))
		return Bridge(
			bridge: bridge,
			handles: [fromGuest.fileHandleForWriting, toGuest.fileHandleForReading])
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

	@Test @MainActor func aBridgeKeepsItsSocketFresh() async throws {
		let port = makeBridge("ttykeep")
		port.bridge.start()
		defer { port.bridge.stop() }
		#expect(await eventually(timeout: .seconds(10)) {
			FileManager.default.fileExists(atPath: port.socketPath)
		})
		age(port.socketPath)
		#expect(modified(port.socketPath) < Date(timeIntervalSince1970: 1_600_000_000))

		let recent = Date().addingTimeInterval(-60)
		#expect(await eventually(timeout: .seconds(10)) { modified(port.socketPath) > recent })
	}

	@Test @MainActor func stopEndsTheKeepAlive() async throws {
		let port = makeBridge("ttystop")
		port.bridge.start()
		port.bridge.stop()
		try await Task.sleep(for: .milliseconds(300))
		#expect(!FileManager.default.fileExists(atPath: port.socketPath))   // never recreated
	}
}
