//
//  PTYProcessStreamTests.swift
//  MachmanUITests
//
//  The PTY-backed byte stream behind the SSH tabs, exercised with plain system binaries
//  (/bin/cat, /usr/bin/true, /bin/sh) — no ssh, no network.
//

import Testing
import Foundation
import MachmanUI
import MachmanTestSupport

struct PTYProcessStreamTests {

	@Test @MainActor func catEchoesThroughThePTY() async throws {
		let stream = PTYProcessStream(executablePath: "/bin/cat", arguments: [])
		let sink = StreamSink()
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
		let sink = StreamSink()
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
		let sink = StreamSink()
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

	// P20: ssh redraws on SIGWINCH alone, and TIOCSWINSZ signals the pty's FOREGROUND process
	// group — which exists only once the pty is the child's controlling terminal. Foundation's
	// Process hands the child the pty as stdio but no setsid/TIOCSCTTY, so today nobody is
	// signalled. Known-failing until the stream spawns through forkpty/login_tty (lane 2f);
	// the moment that lands, withKnownIssue itself fails ("not recorded"): delete the wrapper.
	@Test @MainActor func resizeDeliversSIGWINCHToTheChild() async throws {
		await withKnownIssue(
			"P20: the pty is not the child's controlling terminal, so a resize signals no one"
		) {
			// The loop ends with its parent: the child leads its own process group, so if the
			// test process dies without stream.stop() (a crash, a timeout kill, ^C of the
			// runner) nothing else would ever stop it — it would fork sleep 20x/s for good.
			let stream = PTYProcessStream(
				executablePath: "/bin/sh",
				arguments: ["-c", "trap 'echo GOT_WINCH' WINCH; echo READY; "
					+ "while kill -0 $PPID 2>/dev/null; do sleep 0.05; done"])
			let sink = StreamSink()
			stream.onData = { sink.append($0) }
			defer { stream.stop() }
			#expect(stream.connect())
			for _ in 0..<250 where !sink.text.contains("READY") {
				try await Task.sleep(for: .milliseconds(20))
			}
			#expect(sink.text.contains("READY"))   // the trap is installed before the resize
			stream.setWindowSize(cols: 100, rows: 30)
			for _ in 0..<100 where !sink.text.contains("GOT_WINCH") {
				try await Task.sleep(for: .milliseconds(20))
			}
			#expect(sink.text.contains("GOT_WINCH"))
		}
	}

	// Q5: the transcript keeps its last 8 MiB and nothing more alive. A sliced Data head
	// kept the whole buffer — every byte the session ever printed.
	@Test @MainActor func theTranscriptKeepsOnlyItsLastEightMiB() async throws {
		let stream = PTYProcessStream(
			executablePath: "/bin/sh", arguments: ["-c", "head -c 20971520 /dev/zero; printf END"])
		let sink = StreamSink()
		stream.onClose = { sink.markClosed() }
		#expect(stream.connect())
		#expect(await eventually(timeout: .seconds(20)) { sink.isClosed })
		let transcript = stream.transcriptData()
		#expect(transcript.count == 8 << 20)
		#expect(transcript.startIndex == 0, "still holds \(transcript.startIndex) dead bytes")
	}

	@Test func windowSizeAndSendAreSafeBeforeConnect() {
		let stream = PTYProcessStream(executablePath: "/bin/cat", arguments: [])
		stream.setWindowSize(cols: 80, rows: 24)
		stream.send(Data("x".utf8))
		stream.stop()
	}
}
