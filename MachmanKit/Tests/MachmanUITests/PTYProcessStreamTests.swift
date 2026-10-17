//
//  PTYProcessStreamTests.swift
//  MachmanUITests
//
//  The PTY-backed byte stream behind the SSH tabs, exercised with plain system binaries
//  (/bin/cat, /usr/bin/true, /bin/sh, /bin/stty, /bin/sleep) — no ssh, no network.
//

import Testing
import Foundation
@testable import MachmanUI
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

	// P20: ssh forwards a resize on SIGWINCH alone, and TIOCSWINSZ signals the pty's
	// FOREGROUND process group — which exists only because the pty is the child's
	// controlling terminal (Foundation's Process gave it the pty as plain stdio).
	@Test @MainActor func resizeDeliversSIGWINCHToTheChild() async throws {
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

	// P20/P42: password prompts need a /dev/tty, which opens only for a controlling terminal.
	// ssh never opens its pty itself; /bin/sh did, and so got one on its own while ssh had
	// none. stty is no shell: it prints the size only if /dev/tty opens.
	@Test("P42: a child that is no shell opens /dev/tty on its pty")
	@MainActor func aChildThatIsNoShellOpensDevTTY() async throws {
		let stream = PTYProcessStream(
			executablePath: "/bin/stty", arguments: ["-f", "/dev/tty", "size"])
		let sink = StreamSink()
		stream.onData = { sink.append($0) }
		stream.onClose = { sink.markClosed() }
		stream.setWindowSize(cols: 123, rows: 45)
		#expect(stream.connect())
		#expect(await eventually { sink.isClosed })
		#expect(sink.text.contains("45 123"), "got \(sink.text)")
	}

	// P42: an app that quits or crashes leaves the kernel to close the pty's master, and only
	// that hang-up (SIGHUP to the session's leader) ends the child. sleep is no shell.
	@Test("P42: closing the pty's master hangs up a child that is no shell")
	@MainActor func closingTheMasterHangsUpTheChild() async throws {
		let sink = StreamSink()
		let (child, master) = try #require(PTYChild.spawn(
			executablePath: "/bin/sleep", arguments: ["30"], environment: [:], size: nil,
			onExit: { sink.markClosed() }))
		defer { child.terminate() }   // SIGTERM only while the pid is still the child's
		close(master)
		#expect(await eventually { sink.isClosed }, "sleep outlived its pty")
	}

	// P42: a resize reaches the child as SIGWINCH, which TIOCSWINSZ sends to the pty's
	// foreground process group: only a child that took the pty as its controlling terminal
	// leads one. The /bin/sh resize tests can't tell — sh takes the tty on its own.
	@Test("P42: a child that is no shell leads its pty's foreground group")
	@MainActor func aChildThatIsNoShellLeadsTheForegroundGroup() async throws {
		// The fork on the own thread (Q43): a bare PTYChild holds no stream state. A stream's
		// connect() stays on the main actor — the stream is main-confined (its exit and channel
		// callbacks run there).
		let spawned = await onOwnThread {
			PTYChild.spawn(
				executablePath: "/bin/sleep", arguments: ["30"], environment: [:], size: nil,
				onExit: {})
		}
		let (child, master) = try #require(spawned)
		defer {
			close(master)
			child.terminate()
		}
		#expect(tcgetpgrp(master) == child.pid)
	}

	// P20: a reconnect (a new stream on a terminal that keeps its size) starts at that size.
	@Test @MainActor func aSizeSetBeforeConnectIsTheFirstSize() async throws {
		let stream = PTYProcessStream(executablePath: "/bin/sh", arguments: ["-c", "stty size"])
		let sink = StreamSink()
		stream.onData = { sink.append($0) }
		stream.onClose = { sink.markClosed() }
		stream.setWindowSize(cols: 123, rows: 45)
		#expect(stream.connect())
		#expect(await eventually { sink.isClosed })
		#expect(sink.text.contains("45 123"), "got \(sink.text)")
	}

	// P34: a resize drag is a run of sizes; the child hears one SIGWINCH, for the last one.
	@Test @MainActor func aRunOfSizesReachesTheChildOnceAsTheLast() async throws {
		var due: [() -> Void] = []
		let stream = PTYProcessStream(
			executablePath: "/bin/sh",
			arguments: ["-c", "trap 'echo WINCH $(stty size)' WINCH; echo READY; "
				+ "while kill -0 $PPID 2>/dev/null; do sleep 0.05; done"],
			environmentOverrides: [:], schedule: { _, body in due.append(body) })
		let sink = StreamSink()
		stream.onData = { sink.append($0) }
		defer { stream.stop() }
		#expect(stream.connect())
		#expect(await eventually { sink.text.contains("READY") })
		for step in 0..<20 { stream.setWindowSize(cols: 80 + step, rows: 30) }
		#expect(stream.windowSizeWrites == 0)
		due.forEach { $0() }
		#expect(stream.windowSizeWrites == 1)
		#expect(await eventually { sink.text.contains("WINCH 30 99") }, "got \(sink.text)")
	}

	@Test @MainActor func aSizeStillSettlingWhenStoppedNeverReachesThePTY() {
		var due: [() -> Void] = []
		let stream = PTYProcessStream(
			executablePath: "/bin/cat", arguments: [], environmentOverrides: [:],
			schedule: { _, body in due.append(body) })
		#expect(stream.connect())
		stream.setWindowSize(cols: 100, rows: 30)
		stream.stop()
		due.forEach { $0() }
		#expect(stream.windowSizeWrites == 0)
	}

	// No other descriptor of the app reaches ssh (forkpty would hand it every one).
	@Test @MainActor func noStrayDescriptorReachesTheChild() async throws {
		let stray = open("/dev/null", O_RDONLY)   // deliberately not close-on-exec
		defer { close(stray) }
		let stream = PTYProcessStream(
			executablePath: "/bin/sh",
			arguments: ["-c", "if [ -e /dev/fd/\(stray) ]; then echo LEAKED; else echo CLEAN; fi"])
		let sink = StreamSink()
		stream.onData = { sink.append($0) }
		stream.onClose = { sink.markClosed() }
		#expect(stream.connect())
		#expect(await eventually { sink.isClosed })
		#expect(sink.text.contains("CLEAN"), "got \(sink.text)")
	}

	// The child is reaped once it exits — no zombie, whoever still holds the stream.
	@Test @MainActor func anExitedChildIsReaped() async throws {
		let stream = PTYProcessStream(executablePath: "/usr/bin/true", arguments: [])
		let sink = StreamSink()
		stream.onClose = { sink.markClosed() }
		#expect(stream.connect())
		let pid = try #require(stream.childPID)
		#expect(await eventually { sink.isClosed })
		#expect(await eventually { kill(pid, 0) == -1 && errno == ESRCH })
	}

	// stop() ends the child (hang-up, then SIGTERM) and it is reaped; nothing is reported.
	@Test @MainActor func stopEndsAndReapsTheChildSilently() async throws {
		let stream = PTYProcessStream(
			executablePath: "/bin/sh",
			arguments: ["-c", "echo UP; while kill -0 $PPID 2>/dev/null; do sleep 0.05; done"])
		let sink = StreamSink()
		stream.onData = { sink.append($0) }
		stream.onClose = { sink.markClosed() }
		#expect(stream.connect())
		let pid = try #require(stream.childPID)
		#expect(await eventually { sink.text.contains("UP") })
		stream.stop()
		#expect(await eventually { kill(pid, 0) == -1 && errno == ESRCH })
		try await Task.sleep(for: .milliseconds(100))
		#expect(!sink.isClosed)
	}

	@Test func aMissingExecutableFailsToConnect() {
		let stream = PTYProcessStream(executablePath: "/nonexistent/ssh", arguments: [])
		#expect(!stream.connect())
		stream.send(Data("x".utf8))
		stream.stop()
	}

	@Test func windowSizeAndSendAreSafeBeforeConnect() {
		let stream = PTYProcessStream(executablePath: "/bin/cat", arguments: [])
		stream.setWindowSize(cols: 80, rows: 24)
		stream.send(Data("x".utf8))
		stream.stop()
	}
}
