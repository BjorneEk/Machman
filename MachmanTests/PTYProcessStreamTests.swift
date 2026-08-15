//
//  PTYProcessStreamTests.swift
//  MachmanTests
//
//  The PTY-backed byte stream behind the SSH tabs, exercised with plain system binaries
//  (/bin/cat, /usr/bin/true) — no ssh, no network. First @testable import of the app
//  target in this suite (the stream lives in MachmanDesktop, beside the serial client).
//

import Testing
import Foundation
@testable import MachmanDesktop

struct PTYProcessStreamTests {

	private final class Sink: @unchecked Sendable {
		private let lock = NSLock()
		private var data = Data()
		private var closed = false
		func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
		func markClosed() { lock.lock(); closed = true; lock.unlock() }
		var received: Data { lock.lock(); defer { lock.unlock() }; return data }
		var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
	}

	@Test @MainActor func catEchoesThroughThePTY() async throws {
		let stream = PTYProcessStream(executablePath: "/bin/cat", arguments: [])
		let sink = Sink()
		stream.onData = { sink.append($0) }
		stream.onClose = { sink.markClosed() }
		#expect(stream.connect())
		stream.setWindowSize(cols: 80, rows: 24)   // safe while connected
		stream.send(Data("hello\n".utf8))
		for _ in 0..<250 where sink.received.isEmpty {
			try await Task.sleep(for: .milliseconds(20))
		}
		// PTY echo and cat both answer — either way our bytes come back.
		#expect(sink.received.contains(UInt8(ascii: "h")))
		#expect(stream.transcriptData().contains(UInt8(ascii: "h")))
		stream.stop()
		// An explicit stop is not a close event (the tab closed itself).
		try await Task.sleep(for: .milliseconds(50))
		#expect(!sink.isClosed)
	}

	@Test @MainActor func childExitReportsCloseOnce() async throws {
		let stream = PTYProcessStream(executablePath: "/usr/bin/true", arguments: [])
		let sink = Sink()
		stream.onClose = { sink.markClosed() }
		#expect(stream.connect())
		for _ in 0..<250 where !sink.isClosed {
			try await Task.sleep(for: .milliseconds(20))
		}
		#expect(sink.isClosed)
	}

	@Test @MainActor func environmentOverridesReachTheChild() async throws {
		let stream = PTYProcessStream(
			executablePath: "/bin/sh", arguments: ["-c", "echo TERM=$TERM"],
			environmentOverrides: ["TERM": "xterm-machman-test"])
		let sink = Sink()
		stream.onData = { sink.append($0) }
		#expect(stream.connect())
		for _ in 0..<250 where !String(decoding: sink.received, as: UTF8.self)
			.contains("xterm-machman-test") {
			try await Task.sleep(for: .milliseconds(20))
		}
		#expect(String(decoding: sink.received, as: UTF8.self)
			.contains("TERM=xterm-machman-test"))
		stream.stop()
	}

	@Test func windowSizeAndSendAreSafeBeforeConnect() {
		let stream = PTYProcessStream(executablePath: "/bin/cat", arguments: [])
		stream.setWindowSize(cols: 80, rows: 24)
		stream.send(Data("x".utf8))
		stream.stop()
	}
}
