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

	// MARK: agent, scope, VM spec and fixtures (TC4-TC6): pure, nothing is launched

	@Test(
		"TC4: an agent's environment carries the suite, its scope and the lab variables, nothing else"
	)
	func agentEnvironment() throws {
		let scope = try LabScope.make(in: TestEnvironment.scratch + "scopes-\(UUID().uuidString)")
		let inherited = [
			"MACHMAN_SUITE_ID": "com.gustaffranzen.Machman.test-abcd", "MACHMAN_LAB": "1",
			"MACHMAN_LAB_RUN": "/tmp/mml.abcd", "MACHMAN_LAB_TIERS": "smoke",
			"SSH_AUTH_SOCK": "/tmp/agent.sock", "SECRET": "x", "HOME": "/Users/real",
			"TMPDIR": "/var/folders/xx/T/", "USER": "me", "LOGNAME": "me",
			"MACHMAN_DATA_DIR": "/tmp/mml.abcd/data",
		]
		let environment = LabAgent.environment(
			scope: scope, inherited: inherited, extra: ["MACHMAN_LAB_DEVICES": "hid"])
		#expect(environment["MACHMAN_SUITE_ID"] == "com.gustaffranzen.Machman.test-abcd")
		#expect(environment["MACHMAN_DATA_DIR"] == scope.dataDir)
		#expect(environment["CFFIXED_USER_HOME"] == scope.homeDir)
		#expect(environment["HOME"] == scope.homeDir)
		#expect(environment["TMPDIR"] == "/var/folders/xx/T/")
		#expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
		#expect(environment["MACHMAN_LAB_RUN"] == "/tmp/mml.abcd")
		#expect(environment["MACHMAN_LAB_TIERS"] == "smoke")
		#expect(environment["MACHMAN_LAB_DEVICES"] == "hid")
		#expect(environment["MACHMAN_LAB_ANSWERS"] == scope.answersPath)
		#expect(environment["MACHMAN_LAB_AGENT_CONTROL"] == scope.controlPath)
		#expect(environment["USER"] == "me")
		#expect(environment["MACHMAN_LAB"] == nil)
		#expect(environment["SSH_AUTH_SOCK"] == nil)
		#expect(environment["SECRET"] == nil)
	}

	@Test(
		"TC4: every scope gets its own library, home, answers and control socket inside the run"
	)
	func scopesAreSeparate() throws {
		let dir = TestEnvironment.scratch + "scopes-\(UUID().uuidString)"
		let first = try LabScope.make(in: dir)
		let second = try LabScope.make(in: dir)
		#expect(first.id != second.id)
		#expect(first.dataDir != second.dataDir && first.homeDir != second.homeDir)
		#expect(first.answersPath != second.answersPath)
		for scope in [first, second] {
			#expect(scope.dir.hasPrefix(dir))
			let answers = try Data(contentsOf: URL(fileURLWithPath: scope.answersPath))
			let object = try JSONSerialization.jsonObject(with: answers) as? [String: Any]
			#expect(object?.isEmpty == true)
		}
		// Under a real run the control path names the run's token and fits sun_path.
		let real = try LabScope.make(in: Lab.scopesDir)
		#expect(real.controlPath.contains(Lab.token))
		#expect(real.controlPath.utf8.count <= 103)
	}

	@Test("TC4: answers written to a scope read back as the agent reads them")
	func answersRoundTrip() throws {
		let scope = try LabScope.make(in: TestEnvironment.scratch + "scopes-\(UUID().uuidString)")
		try scope.writeAnswers([
			"agent.quit": "Quit", "vmhost.stop": ["button": "Stop", "holdSeconds": 2],
		])
		let data = try Data(contentsOf: URL(fileURLWithPath: scope.answersPath))
		let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
		#expect(object["agent.quit"] as? String == "Quit")
		let held = try #require(object["vmhost.stop"] as? [String: Any])
		#expect(held["button"] as? String == "Stop")
		#expect(held["holdSeconds"] as? Int == 2)
	}

	@Test("TC5: a lab VM stays within two vCPUs, 2 GB, four consoles and no audio")
	func specLimits() throws {
		let alpine = LabVMSpec.Boot.alpine()
		try LabVMSpec(name: "ok", boot: alpine, cpus: 2, memoryGiB: 2, consolePorts: 4).validate()
		let bad: [LabVMSpec] = [
			LabVMSpec(name: "", boot: alpine), LabVMSpec(name: "a/b", boot: alpine),
			LabVMSpec(name: ".hidden", boot: alpine), LabVMSpec(name: "x", boot: alpine, cpus: 3),
			LabVMSpec(name: "x", boot: alpine, cpus: 0),
			LabVMSpec(name: "x", boot: alpine, memoryGiB: 3),
			LabVMSpec(name: "x", boot: alpine, consolePorts: 5),
			LabVMSpec(name: "x", boot: alpine, consolePorts: 0),
			LabVMSpec(name: "x", boot: alpine, devices: [.audioInput]),
			LabVMSpec(name: "x", boot: alpine, devices: [.keyboard, .audioOutput]),
		]
		for spec in bad {
			#expect(throws: LabError.self) { try spec.validate() }
		}
	}

	@Test("TC5: lab guests count running vmhost and QEMU pid files toward the cap of two")
	func guestCount() throws {
		let dir = TestEnvironment.scratch + "pids-\(UUID().uuidString)"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		try LabProcesses.writePid(getpid(), kind: "vmhost", name: "01-a", in: dir)
		let dead = Process()
		dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
		try dead.run()
		dead.waitUntilExit()
		try LabProcesses.writePid(dead.processIdentifier, kind: "qemu", name: "b", in: dir)
		try LabProcesses.writePid(getpid(), kind: "agent", name: "01", in: dir)
		#expect(LabProcesses.liveGuestCount(in: dir) == 1)
		try LabProcesses.writePid(getpid(), kind: "qemu", name: "c", in: dir)
		#expect(LabProcesses.liveGuestCount(in: dir) == 2)
	}

	@Test("TC5: a lab pid file name keeps only safe characters")
	func pidFileName() {
		let path = LabProcesses.pidFile(kind: "vmhost", name: "01-dev copy/x", in: "/p")
		#expect(path == "/p/vmhost-01-dev_copy_x.pid")
	}

	@Test("TC6: a fixture that was never fetched names the fetch command")
	func fixtureMissing() {
		let cache = TestEnvironment.scratch + "cache-\(UUID().uuidString)"
		do {
			_ = try LabFixtures.path("nothing-here.raw", cache: cache)
			Issue.record("a missing fixture should throw")
		} catch {
			#expect("\(error)".contains("scripts/lab/fetch.sh fetch nothing-here.raw"))
		}
	}

	@Test("TC6: a fixture clone is a writable copy in the scope's images dir")
	func fixtureClone() async throws {
		let cache = TestEnvironment.scratch + "cache-\(UUID().uuidString)"
		let fixtures = cache + "/fixtures"
		try FileManager.default.createDirectory(atPath: fixtures, withIntermediateDirectories: true)
		try Data("kernel bytes".utf8).write(to: URL(fileURLWithPath: fixtures + "/k"))
		try Data("stamp".utf8).write(to: URL(fileURLWithPath: fixtures + "/k.stamp"))
		chmod(fixtures + "/k", 0o444)
		let source = try LabFixtures.path("k", cache: cache)
		let images = TestEnvironment.scratch + "images-\(UUID().uuidString)"
		let clone = try await LabFixtures.clone(source, as: "vm-Image", into: images)
		#expect(clone == images + "/vm-Image")
		#expect(try String(contentsOfFile: clone, encoding: .utf8) == "kernel bytes")
		let mode = try FileManager.default.attributesOfItem(atPath: clone)[.posixPermissions]
		#expect((mode as? NSNumber)?.intValue == 0o644)
	}
}
