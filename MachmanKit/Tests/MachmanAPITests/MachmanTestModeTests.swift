//
//  MachmanTestModeTests.swift
//  MachmanAPITests
//
//  The one predicate behind the test-only seams (TB1): only a Debug build under a per-run
//  .test-<token> suite is in test mode, so the .dev suite, the Release suite and Release
//  builds never meet a seam, and the lab's variables mean nothing to them.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport

struct MachmanTestModeTests {
	private static let dev = "com.gustaffranzen.Machman.dev"
	private static let release = "com.gustaffranzen.Machman"
	private static let test = "com.gustaffranzen.Machman.test-abc1"

	// Every lab variable set, as a lab run would.
	private static let labVariables = [
		"MACHMAN_LAB_ANSWERS": "/tmp/mml.abc1/answers.json",
		"MACHMAN_LAB_SSHD_HOSTKEY": "/tmp/mml.abc1/sshd/host.pub",
		"MACHMAN_LAB_DEVICES": "hid",
		"MACHMAN_LAB_AGENT_CONTROL": "/tmp/mml.abc1/agent.ctl",
	]

	@Test("Q18: only com.gustaffranzen.Machman.test-<token> is a test suite (TB1)")
	func onlyTheTestSuitePrefixWithATokenIsATestSuite() {
		let prefix = "com.gustaffranzen.Machman"
		let not = [
			Self.dev, Self.release, "", prefix + ".test-", prefix + ".testX", prefix + ".test-a/b",
			prefix + ".test-abc.agent", prefix + ".dev.test-abc", " " + Self.test,
			prefix + ".test-ab c", prefix + ".test-\u{0661}\u{0662}", prefix + ".test-abc\n",
			"com.gustaffranzen.machman.test-abc",
		]
		for suite in not {
			#expect(!MachmanTestMode.isTestSuite(suite), "\(suite.debugDescription)")
		}
		for suite in [prefix + ".test-abc", prefix + ".test-A1b2", TestEnvironment.suiteID] {
			#expect(MachmanTestMode.isTestSuite(suite), "\(suite.debugDescription)")
		}
		#expect(MachmanTestMode.suitePrefix == TestEnvironment.suitePrefix)
	}

	@Test("Q18: test mode is off for the dev and Release suites and in a release build (TB1)")
	func testModeIsOffOutsideATestSuiteOrInRelease() {
		var environment = Self.labVariables
		environment["MACHMAN_DATA_DIR"] = "/tmp/mml.abc1/data"
		for suite in [Self.dev, Self.release] {
			#expect(!MachmanTestMode.isActive(suiteID: suite, debugBuild: true))
			#expect(LabEnvironment(suiteID: suite, environment: environment, debugBuild: true)
				== nil)
		}
		#expect(!MachmanTestMode.isActive(suiteID: Self.test, debugBuild: false))
		#expect(LabEnvironment(suiteID: Self.test, environment: environment, debugBuild: false)
			== nil)
		#expect(MachmanTestMode.isActive(suiteID: Self.test, debugBuild: true))
		#expect(LabEnvironment(suiteID: Self.test, environment: environment, debugBuild: true)
			!= nil)
	}

	@Test("Q18: a headless run is itself under test mode (TB1)")
	func aHeadlessRunIsUnderTestMode() throws {
		#expect(MachmanTestMode.isDebugBuild)
		#expect(MachmanTestMode.isActive)
		let lab = try #require(LabEnvironment.current)
		#expect(lab.suiteID == TestEnvironment.suiteID)
		#expect(lab.token == TestEnvironment.token)
	}

	@Test("Q18: lab variables parse or stay off (TB1)")
	func labVariablesParseOrStayOff() throws {
		let lab = try #require(LabEnvironment(
			suiteID: Self.test, environment: Self.labVariables, debugBuild: true))
		#expect(lab.token == "abc1")
		#expect(lab.answersPath == "/tmp/mml.abc1/answers.json")
		#expect(lab.sshdHostKeyPath == "/tmp/mml.abc1/sshd/host.pub")
		#expect(lab.deviceOptIns == ["hid"])
		#expect(lab.agentControlPath == "/tmp/mml.abc1/agent.ctl")

		let devices = try #require(LabEnvironment(
			suiteID: Self.test, environment: ["MACHMAN_LAB_DEVICES": " HID, ,clipboard ,"],
			debugBuild: true))
		#expect(devices.deviceOptIns == ["hid", "clipboard"])

		// Relative paths, and a control socket outside this run's sandbox, are refused.
		let refused = try #require(LabEnvironment(
			suiteID: Self.test,
			environment: [
				"MACHMAN_LAB_ANSWERS": "answers.json",
				"MACHMAN_LAB_SSHD_HOSTKEY": "host.pub",
				"MACHMAN_LAB_AGENT_CONTROL": "/tmp/mml.zzzz/agent.ctl",
			],
			debugBuild: true))
		#expect(refused.answersPath == nil)
		#expect(refused.sshdHostKeyPath == nil)
		#expect(refused.agentControlPath == nil)
		let relativeControl = try #require(LabEnvironment(
			suiteID: Self.test, environment: ["MACHMAN_LAB_AGENT_CONTROL": "abc1/agent.ctl"],
			debugBuild: true))
		#expect(relativeControl.agentControlPath == nil)

		let empty = try #require(LabEnvironment(
			suiteID: Self.test, environment: [:], debugBuild: true))
		#expect(empty.answersPath == nil)
		#expect(empty.deviceOptIns.isEmpty)

		// Intervals: positive finite seconds under a MACHMAN_LAB_ name, nothing else.
		let intervals = try #require(LabEnvironment(
			suiteID: Self.test,
			environment: [
				"MACHMAN_LAB_KEEPALIVE_SECONDS": "2.5", "MACHMAN_LAB_ZERO": "0",
				"MACHMAN_LAB_WORD": "soon", "MACHMAN_LAB_INF": "inf", "OTHER_SECONDS": "3",
			],
			debugBuild: true))
		#expect(intervals.seconds("MACHMAN_LAB_KEEPALIVE_SECONDS") == 2.5)
		#expect(intervals.seconds("MACHMAN_LAB_ZERO") == nil)
		#expect(intervals.seconds("MACHMAN_LAB_WORD") == nil)
		#expect(intervals.seconds("MACHMAN_LAB_INF") == nil)
		#expect(intervals.seconds("OTHER_SECONDS") == nil)
		#expect(intervals.seconds("MACHMAN_LAB_MISSING") == nil)
	}

	@Test("Q18: a vmhost inherits only the suite, fake home, data dir and lab variables (TB1)")
	func forwardedVariablesAreTheContractsSet() throws {
		var environment = Self.labVariables
		environment["MACHMAN_SUITE_ID"] = "ignored: the suite comes from the argument"
		environment["CFFIXED_USER_HOME"] = "/tmp/mml.abc1/home"
		environment["HOME"] = "/tmp/mml.abc1/home"
		environment["MACHMAN_DATA_DIR"] = "/tmp/mml.abc1/data"
		environment["MACHMAN_LAB"] = "1"
		environment["PATH"] = "/usr/bin:/bin"
		environment["SSH_AUTH_SOCK"] = "/private/tmp/agent.sock"
		environment["TMPDIR"] = "/var/folders/x/T/"
		let lab = try #require(LabEnvironment(
			suiteID: Self.test, environment: environment, debugBuild: true))
		var expected = Self.labVariables
		expected["MACHMAN_SUITE_ID"] = Self.test
		expected["CFFIXED_USER_HOME"] = "/tmp/mml.abc1/home"
		expected["HOME"] = "/tmp/mml.abc1/home"
		expected["MACHMAN_DATA_DIR"] = "/tmp/mml.abc1/data"
		#expect(lab.forwardedVariables == expected)

		// Unset or empty: not forwarded at all.
		let bare = try #require(LabEnvironment(
			suiteID: Self.test, environment: ["MACHMAN_DATA_DIR": ""], debugBuild: true))
		#expect(bare.forwardedVariables == ["MACHMAN_SUITE_ID": Self.test])
	}
}
