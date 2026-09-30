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
		// No EnvironmentVariables on purpose: the vmhost self-identifies by bundle id.
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
