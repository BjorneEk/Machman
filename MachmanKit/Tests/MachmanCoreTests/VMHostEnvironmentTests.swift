//
//  VMHostEnvironmentTests.swift
//  MachmanCoreTests
//
//  TB3: the environment a spawned vmhost gets. OpenConfiguration.environment replaces the
//  child's whole environment, so a test-suite vmhost that inherited nothing resolved the .dev
//  suite: its tty sockets in the .dev runtime dir, its log under the .dev subsystem, and test
//  mode off (windows, audio, real alerts). Outside test mode the dictionary is today's.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport
@testable import MachmanCore

struct VMHostEnvironmentTests {
	private static let labVariables = [
		"MACHMAN_LAB_ANSWERS": "/tmp/mml.abc1/answers.json",
		"MACHMAN_LAB_DEVICES": "hid",
		"MACHMAN_DATA_DIR": "/tmp/mml.abc1/data",
		"CFFIXED_USER_HOME": "/tmp/mml.abc1/home",
		"PATH": "/usr/bin:/bin",
	]

	@Test("Q18: outside test mode a vmhost gets only MACHMAN_VERSION (TB3)")
	func outsideTestModeAVMHostGetsOnlyTheVersion() {
		#expect(RoutingMachman.vmhostEnvironment(daemonVersion: "1.0.12", lab: nil)
			== ["MACHMAN_VERSION": "1.0.12"])
		for suite in ["com.gustaffranzen.Machman.dev", "com.gustaffranzen.Machman"] {
			let lab = LabEnvironment(
				suiteID: suite, environment: Self.labVariables, debugBuild: true)
			#expect(lab == nil)
			#expect(RoutingMachman.vmhostEnvironment(daemonVersion: "1.0.12", lab: lab)
				== ["MACHMAN_VERSION": "1.0.12"])
		}
	}

	@Test("Q18: a test-suite vmhost inherits the suite, home, data dir and lab variables (TB3)")
	func underATestSuiteAVMHostInheritsTheLab() throws {
		var environment = Self.labVariables
		environment["MACHMAN_LAB_VERSION"] = "stray"
		let suite = "com.gustaffranzen.Machman.test-abc1"
		let lab = try #require(LabEnvironment(
			suiteID: suite, environment: environment, debugBuild: true))
		#expect(RoutingMachman.vmhostEnvironment(daemonVersion: "1.0.12", lab: lab) == [
			"MACHMAN_VERSION": "1.0.12",
			"MACHMAN_SUITE_ID": suite,
			"MACHMAN_DATA_DIR": "/tmp/mml.abc1/data",
			"CFFIXED_USER_HOME": "/tmp/mml.abc1/home",
			"MACHMAN_LAB_ANSWERS": "/tmp/mml.abc1/answers.json",
			"MACHMAN_LAB_DEVICES": "hid",
			"MACHMAN_LAB_VERSION": "stray",
		])
	}

	// E50: both background launches kept OpenConfiguration's defaults, so each VM start
	// recorded Machman VM in Recent Items, and a launch Launch Services wanted confirmed raised
	// its dialog from the background agent instead of failing into an error the client sees.
	@Test("E50: a vmhost's launch stays out of Recent Items and never prompts")
	@MainActor func aVMHostsLaunchStaysQuiet() {
		let configuration = RoutingMachman.vmhostLaunchConfiguration(
			arguments: ["--vm", "alpha"], environment: ["MACHMAN_VERSION": "1.0.12"])
		#expect(!configuration.addsToRecentItems)
		#expect(!configuration.promptsUserIfNeeded)
		#expect(!configuration.activates)
		#expect(configuration.createsNewApplicationInstance)
		#expect(configuration.arguments == ["--vm", "alpha"])
		#expect(configuration.environment == ["MACHMAN_VERSION": "1.0.12"])
	}

	// The desktop's launch of the agent is app-target code: read from its source. Every
	// OpenConfiguration it makes sets both flags off.
	@Test("E50: the desktop's agent launch stays out of Recent Items and never prompts")
	func theAgentsLaunchStaysQuiet() throws {
		for file in [
			"MachmanDesktop/DaemonConnection.swift",
			"MachmanKit/Sources/MachmanCore/RoutingMachman+HostSupervisor.swift",
		] {
			let made = try SourceScan.hits(#"OpenConfiguration\(\)"#, in: [file]).count
			#expect(made > 0, "\(file)")
			for flag in ["addsToRecentItems", "promptsUserIfNeeded"] {
				let off = try SourceScan.hits("\\.\(flag) = false", in: [file]).count
				#expect(off == made, "\(file): \(flag) is off for \(off) of \(made)")
			}
		}
	}
}
