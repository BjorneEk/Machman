//
//  LaunchAgentManagerTests.swift
//  MachmanTests
//
//  All against injected throwaway directories — these tests cannot reach the real
//  ~/Library/LaunchAgents by construction, and each cleans its tmp dir in a defer so a
//  mid-test failure leaves no garbage either. remove() is always called with
//  canBootout: false here, so launchctl is never spawned.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
@testable import MachmanCore

struct LaunchAgentManagerTests {
	private func makeManager(agentsDir: String = "/nonexistent") -> LaunchAgentManager {
		LaunchAgentManager(
			suiteID: "com.test.suite",
			vmhostExecutablePath: "/Test/MachmanVMHost.app/Contents/MacOS/MachmanVMHost",
			vmsDir: "/test/vms",
			runtimeDir: "/test/rt",
			agentsDir: agentsDir)
	}

	@Test func labelUsesTheNameWhenLaunchdSafe() {
		let manager = makeManager()
		#expect(manager.label(for: "Debian-12_test.x") == "com.test.suite.vm.Debian-12_test.x")
	}

	@Test func labelFallsBackToADeterministicHash() {
		let manager = makeManager()
		let hostile = "my vm ✨"
		let label = manager.label(for: hostile)
		#expect(label == "com.test.suite.vm.h\(MachmanPaths.shortHash(hostile))")
		#expect(label == manager.label(for: hostile))              // recomputable
		#expect(label != manager.label(for: hostile + "2"))        // still per-name
		let long = String(repeating: "a", count: 65)
		#expect(manager.label(for: long).contains(".vm.h"))        // length also falls back
	}

	@Test func plistPinsTheContract() throws {
		let manager = makeManager()
		let dict = manager.plistDictionary(for: "Debian")
		#expect(dict["Label"] as? String == "com.test.suite.vm.Debian")
		#expect(dict["RunAtLoad"] as? Bool == true)
		#expect(dict["KeepAlive"] as? Bool == false)
		#expect(dict["LimitLoadToSessionType"] as? String == "Aqua")
		// No EnvironmentVariables outside a test suite: the vmhost self-identifies by bundle id.
		#expect(dict["EnvironmentVariables"] == nil)
		let args = try #require(dict["ProgramArguments"] as? [String])
		#expect(args == [
			"/Test/MachmanVMHost.app/Contents/MacOS/MachmanVMHost",
			"--data-dir", "/test/vms",
			"--vm", "Debian",
			"--socket", MachmanPaths.vmSocketPath(vm: "Debian", runtimeDir: "/test/rt"),
			"--autostart",
		])
	}

	// TB4: a test-suite job carries what a spawned vmhost inherits — launchd would start its
	// vmhost with launchd's environment, which resolves the .dev suite.
	@Test("Q18: a test-suite autostart plist carries the lab environment (TB4)")
	func aTestSuitePlistCarriesTheLabEnvironment() throws {
		let suite = "com.gustaffranzen.Machman.test-abc1"
		let lab = try #require(LabEnvironment(
			suiteID: suite,
			environment: [
				"CFFIXED_USER_HOME": "/tmp/mml.abc1/home", "MACHMAN_DATA_DIR": "/tmp/mml.abc1/data",
				"MACHMAN_LAB_ANSWERS": "/tmp/mml.abc1/answers.json", "PATH": "/usr/bin",
			],
			debugBuild: true))
		var manager = makeManager()
		manager.environment = LaunchAgentManager.labEnvironment(lab: lab)
		let plist = manager.plistDictionary(for: "Debian")
		#expect(plist["EnvironmentVariables"] as? [String: String] == [
			"MACHMAN_SUITE_ID": suite,
			"CFFIXED_USER_HOME": "/tmp/mml.abc1/home",
			"MACHMAN_DATA_DIR": "/tmp/mml.abc1/data",
			"MACHMAN_LAB_ANSWERS": "/tmp/mml.abc1/answers.json",
		])
		#expect(plist["Label"] as? String == "com.test.suite.vm.Debian")

		// And it reaches the file: a plist written once the lab set it.
		let tmp = TestEnvironment.scratch + "machman-agents-\(UUID().uuidString)"
		defer { try? FileManager.default.removeItem(atPath: tmp) }
		var writing = makeManager(agentsDir: tmp)
		writing.environment = manager.environment
		try writing.install(vm: "Debian")
		let data = try #require(
			FileManager.default.contents(atPath: writing.plistPath(for: "Debian")))
		let parsed = try PropertyListSerialization.propertyList(
			from: data, format: nil) as? [String: Any]
		#expect(parsed?["EnvironmentVariables"] as? [String: String] == manager.environment)
	}

	@Test("Q18: outside test mode autostart plists carry no environment (TB4)")
	func outsideTestModePlistsCarryNoEnvironment() {
		#expect(LaunchAgentManager.labEnvironment(lab: nil).isEmpty)
		for suite in ["com.gustaffranzen.Machman.dev", "com.gustaffranzen.Machman"] {
			let lab = LabEnvironment(
				suiteID: suite, environment: ["MACHMAN_LAB_ANSWERS": "/tmp/a.json"],
				debugBuild: true)
			#expect(LaunchAgentManager.labEnvironment(lab: lab).isEmpty)
		}
		var manager = makeManager()
		manager.environment = LaunchAgentManager.labEnvironment(lab: nil)
		#expect(manager.plistDictionary(for: "Debian")["EnvironmentVariables"] == nil)
	}

	@Test func installRemoveRoundTrip() throws {
		let tmp = TestEnvironment.scratch + "machman-agents-\(UUID().uuidString)"
		defer { try? FileManager.default.removeItem(atPath: tmp) }
		let manager = makeManager(agentsDir: tmp)

		try manager.install(vm: "Debian")
		let path = tmp + "/com.test.suite.vm.Debian.plist"
		let data = try #require(FileManager.default.contents(atPath: path))
		let parsed = try PropertyListSerialization.propertyList(
			from: data, format: nil) as? [String: Any]
		#expect(parsed?["Label"] as? String == "com.test.suite.vm.Debian")

		manager.remove(vm: "Debian", canBootout: false)
		#expect(!FileManager.default.fileExists(atPath: path))
	}

	@Test func installIfChangedRewritesOnlyOnDrift() throws {
		let tmp = TestEnvironment.scratch + "machman-agents-\(UUID().uuidString)"
		defer { try? FileManager.default.removeItem(atPath: tmp) }

		let manager = makeManager(agentsDir: tmp)
		#expect(try manager.installIfChanged(vm: "Debian") == true)     // first write
		#expect(try manager.installIfChanged(vm: "Debian") == false)    // byte-identical

		// The self-heal case: the vmhost executable moved (DerivedData shuffle).
		var moved = makeManager(agentsDir: tmp)
		moved = LaunchAgentManager(
			suiteID: moved.suiteID,
			vmhostExecutablePath: "/Elsewhere/MachmanVMHost",
			vmsDir: moved.vmsDir, runtimeDir: moved.runtimeDir, agentsDir: tmp)
		#expect(try moved.installIfChanged(vm: "Debian") == true)
		let data = try #require(
			FileManager.default.contents(atPath: moved.plistPath(for: "Debian")))
		let parsed = try PropertyListSerialization.propertyList(
			from: data, format: nil) as? [String: Any]
		#expect((parsed?["ProgramArguments"] as? [String])?.first == "/Elsewhere/MachmanVMHost")
	}
}
