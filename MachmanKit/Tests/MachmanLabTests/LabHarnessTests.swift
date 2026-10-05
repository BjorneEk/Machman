//
//  LabHarnessTests.swift
//  MachmanLabTests
//
//  L2 harness — the lab's own machinery; runs under scripts/lab.sh in every mode
//

import Foundation
import Testing
import MachmanTestSupport

@Suite("Lab harness", .enabled(if: Lab.runs(.harness)))
struct LabHarnessTests {
	@Test("TC1: lab tiers parse from MACHMAN_LAB_TIERS")
	func tiersParse() {
		#expect(Lab.tiers(from: "harness, smoke,bogus,,l3") == [.harness, .smoke, .l3])
		#expect(Lab.tiers(from: nil).isEmpty)
	}

	@Test("TC1: the lab is active only inside its own run sandbox")
	func activeOnlyInOwnRun() {
		let good = ["MACHMAN_LAB": "1", "MACHMAN_LAB_RUN": "/tmp/mml.ab12"]
		#expect(Lab.isActive(environment: good, token: "ab12"))
		#expect(!Lab.isActive(environment: ["MACHMAN_LAB_RUN": "/tmp/mml.ab12"], token: "ab12"))
		var off = good
		off["MACHMAN_LAB"] = "0"
		#expect(!Lab.isActive(environment: off, token: "ab12"))
		#expect(!Lab.isActive(environment: good, token: "ab123"))
		var test = good
		test["MACHMAN_LAB_RUN"] = "/tmp/mmt.ab12"
		#expect(!Lab.isActive(environment: test, token: "ab12"))
		var slash = good
		slash["MACHMAN_LAB_RUN"] = "/tmp/mml.ab12/"
		#expect(!Lab.isActive(environment: slash, token: "ab12"))
	}

	// MARK: console client (TC2) and unified-log reader (TC3)

	@Test("TC2: the console client sees output that arrived before it connected")
	func consoleSeesEarlierOutput() async throws {
		let server = try FakeConsoleServer(
			greeting: "boot noise\r\nLAB-READY 6.0-test\r\n# ", respond: { _ in ("", 0) })
		defer { server.stop() }
		let console = try await LabConsole.connect(server.path, transcript: "tc2-early")
		defer { console.close() }
		let groups = try await console.expect("LAB-READY (\\S+)", timeout: .seconds(20))
		#expect(groups[1] == "6.0-test")
	}

	@Test("TC2: run returns a command's output and status without the echoed command")
	func consoleRun() async throws {
		let server = try FakeConsoleServer(greeting: "# ") { command in
			command == "uname -r" ? ("6.0-test", 0) : ("", 3)
		}
		defer { server.stop() }
		let console = try await LabConsole.connect(server.path, transcript: "tc2-run")
		defer { console.close() }
		let first = try await console.run("uname -r", timeout: .seconds(20))
		#expect(first.status == 0)
		#expect(first.output == "6.0-test")
		let second = try await console.run("false", timeout: .seconds(20))
		#expect(second.status == 3)
		#expect(second.output == "")
	}

	@Test("TC2: expect names the pattern and the console's last output when it times out")
	func consoleExpectTimeout() async throws {
		let server = try FakeConsoleServer(
			greeting: "nothing to see\r\n", respond: { _ in ("", 0) })
		defer { server.stop() }
		let console = try await LabConsole.connect(server.path, transcript: "tc2-timeout")
		defer { console.close() }
		do {
			try await console.expect("NEVER", timeout: .seconds(2))
			Issue.record("expect should have timed out")
		} catch let LabError.expectTimeout(pattern, tail) {
			#expect(pattern == "NEVER")
			#expect(tail.contains("nothing to see"))
		}
	}

	@Test("TC2: a console that closes fails expect at once")
	func consoleClosedFailsFast() async throws {
		let server = try FakeConsoleServer(greeting: "hi\r\n", respond: { _ in ("", 0) })
		defer { server.stop() }
		let console = try await LabConsole.connect(server.path, transcript: "tc2-closed")
		defer { console.close() }
		try await console.expect("hi", timeout: .seconds(20))
		server.closeClient()
		let started = ContinuousClock.now
		do {
			try await console.expect("NEVER", timeout: .seconds(30))
			Issue.record("expect should have failed")
		} catch LabError.consoleClosed {
			#expect(ContinuousClock.now - started < .seconds(10))
		}
	}

	@Test("TC2: colour codes and carriage returns never split a match")
	func consoleCleansEscapes() async throws {
		let server = try FakeConsoleServer(greeting: "", respond: { _ in ("", 0) })
		defer { server.stop() }
		let console = try await LabConsole.connect(server.path, transcript: "tc2-escapes")
		defer { console.close() }
		server.send("\u{1B}[1;32mLAB\u{1B}[0m-REA\rDY ok\r\n")
		try await console.expect("LAB-READY ok", timeout: .seconds(20))
	}

	@Test("TC2: the transcript keeps the console's bytes without carriage returns")
	func consoleTranscript() async throws {
		let greeting = "first line\r\nsecond line\r\n"
		let server = try FakeConsoleServer(greeting: greeting, respond: { _ in ("", 0) })
		defer { server.stop() }
		let console = try await LabConsole.connect(server.path, transcript: "tc2-transcript")
		defer { console.close() }
		try await console.expect("second line", timeout: .seconds(20))
		try await Task.sleep(for: .milliseconds(200))
		let kept = try String(contentsOfFile: console.transcriptPath, encoding: .utf8)
		#expect(kept == greeting.replacingOccurrences(of: "\r", with: ""))
	}

	@Test("TC3: the lab log finds a line written after the mark")
	func logFindsLaterLine() async throws {
		let path = TestEnvironment.scratch + "lab-log-\(UUID().uuidString).ndjson"
		try "Filtering the log data using \"subsystem == x\"\n{\"eventMessage\":\"old\"}\n"
			.write(toFile: path, atomically: true, encoding: .utf8)
		let mark = LabLog.mark(path: path)
		let line = "{\"eventMessage\":\"[log] test mode: agent under X\",\"processID\":7}\n"
		Task {
			try await Task.sleep(for: .seconds(1))
			let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
			try handle.seekToEnd()
			try handle.write(contentsOf: Data(line.utf8))
			try handle.close()
		}
		let entry = try await LabLog.waitFor(
			"test mode: agent under", after: mark, timeout: .seconds(10), path: path)
		#expect(entry.processID == 7)
		#expect(LabLog.entries(after: mark, path: path).count == 1)
	}

	@Test("TC3: the lab log skips malformed and partial lines")
	func logSkipsBadLines() throws {
		let path = TestEnvironment.scratch + "lab-log-\(UUID().uuidString).ndjson"
		try "garbage\n{\"eventMessage\":\"good\"}\n{\"eventMessage\":\"partial\"}"
			.write(toFile: path, atomically: true, encoding: .utf8)
		let found = LabLog.entries(path: path)
		#expect(found.count == 1)
		#expect(found.first?.eventMessage == "good")
	}
}
