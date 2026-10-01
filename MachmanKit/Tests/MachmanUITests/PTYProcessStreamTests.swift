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

	// P5: a child that stopped reading (here: raw mode, waiting on a gate file) must not hold
	// the caller in send() — SwiftTerm calls it on the main thread, so a paste beachballed.
	@Test @MainActor func aStalledChildNeverBlocksSend() async throws {
		let gate = TestEnvironment.scratch + "gate-\(UUID().uuidString)"
		let stream = PTYProcessStream(
			executablePath: "/bin/sh",
			arguments: ["-c", "stty raw -echo; echo READY; "
				+ "while [ ! -e '\(gate)' ]; do sleep 0.05; done; head -c 262144 | wc -c; "
				+ "while kill -0 $PPID 2>/dev/null; do sleep 0.05; done"])
		let sink = StreamSink()
		stream.onData = { sink.append($0) }
		defer { stream.stop() }
		#expect(stream.connect())
		#expect(await eventually { sink.text.contains("READY") })
		// The child starts reading 2 s from now, whatever send() does meanwhile.
		DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
			FileManager.default.createFile(atPath: gate, contents: nil)
		}
		let clock = ContinuousClock()
		let start = clock.now
		stream.send(Data(repeating: 0x61, count: 262144))
		let elapsed = start.duration(to: clock.now)
		#expect(elapsed < .milliseconds(500), "send blocked for \(elapsed)")
		#expect(await eventually(timeout: .seconds(8)) { sink.text.contains("262144") })
	}

	// The end is reported once, and after the child's last words.
	@Test @MainActor func anExitIsReportedOnceAfterTheLastOutput() async throws {
		let stream = PTYProcessStream(executablePath: "/bin/sh", arguments: ["-c", "echo LAST"])
		let sink = StreamSink()
		stream.onData = { sink.append($0) }
		stream.onClose = { sink.markClosed() }
		#expect(stream.connect())
		#expect(await eventually { sink.isClosed })
		#expect(sink.textWhenClosed.contains("LAST"))
		try await Task.sleep(for: .milliseconds(200))
		#expect(sink.closeCount == 1)
	}

	// P6: stop() on the main thread while the reader is busy. Before the channel, stop()
	// closed the number under a running reader (ThreadSanitizer: a race in stop()).
	@Test @MainActor func stopRacingABusyReaderIsSafe() async throws {
		for _ in 0..<20 {
			let stream = PTYProcessStream(executablePath: "/usr/bin/yes", arguments: [])
			let sink = StreamSink()
			stream.onData = { sink.append($0) }
			#expect(stream.connect())
			#expect(await eventually { sink.received.count > 10_000 })
			stream.send(Data("q".utf8))
			stream.stop()
		}
	}

	@Test func windowSizeAndSendAreSafeBeforeConnect() {
		let stream = PTYProcessStream(executablePath: "/bin/cat", arguments: [])
		stream.setWindowSize(cols: 80, rows: 24)
		stream.send(Data("x".utf8))
		stream.stop()
	}
}
