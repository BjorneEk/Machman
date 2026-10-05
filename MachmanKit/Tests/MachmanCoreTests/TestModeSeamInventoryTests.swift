//
//  TestModeSeamInventoryTests.swift
//  MachmanCoreTests
//
//  TB13: test behavior lives only where it is inventoried. Every product file that asks the
//  test-mode predicate, reads the lab's environment or variables, answers a prompt for the
//  lab or compiles Debug-only code is listed here, and each listed seam has a Q18 test that
//  proves it inert for the .dev and Release suites. A new seam fails this test until it is
//  added to the inventory with such a test (Stage B lanes add their interval knobs so).
//

import Testing
import Foundation

struct TestModeSeamInventoryTests {
	// What marks a test-mode seam in product code.
	static let markers = [
		#"MachmanTestMode\."#,
		#"LabEnvironment\.current"#,
		#"LabEnvironment\? = \.current"#,
		#"lab: \.current"#,
		#"LabAnswers\.answerIfTesting"#,
		#"MACHMAN_LAB_"#,
		#"#if !?DEBUG"#,
	]

	// Product code: everything that ships (tests, tools and scripts are not product).
	static let productRoots = [
		"MachmanKit/Sources", "MachmanAgent", "MachmanVMHost", "MachmanDesktop",
	]

	// Each file with its seam and the test that proves the seam inert outside test mode.
	static let inventory: [String: String] = [
		"MachmanKit/Sources/MachmanAPI/MachmanTestMode.swift":
			"the predicate and LabEnvironment (MachmanTestModeTests, TB1)",
		"MachmanKit/Sources/MachmanAPI/LabPrompts.swift":
			"prompts answered from the answers file (LabAnswersTests, TB2)",
		"MachmanKit/Sources/MachmanCore/RoutingMachman+HostSupervisor.swift":
			"a vmhost's environment (VMHostEnvironmentTests, TB3)",
		"MachmanKit/Sources/MachmanCore/LaunchAgentManager.swift":
			"an autostart job's environment (LaunchAgentManagerTests, TB4)",
		"MachmanKit/Sources/MachmanCore/VMDevices.swift":
			"the lab device policy (LabDevicePolicyTests, TB5)",
		"MachmanKit/Sources/MachmanCore/GuestSetupInstaller.swift":
			"the lab sshd host-key pin (GuestSetupLabSSHDTests, TB6)",
		"MachmanKit/Sources/MachmanCore/WindowPresenter.swift":
			"no vmhost window, preview or alert (VMHostTestModeTests, TB7)",
		"MachmanKit/Sources/MachmanUI/PromptAlert.swift":
			"no agent alert (PromptAlertTests, TB9)",
		"MachmanAgent/MachmanAgentApp.swift":
			"no menu-bar item or activation, the lab control socket (TB10, TB12)",
		"MachmanAgent/MenuBarView.swift":
			"Open Machman recorded, never performed (AgentQuietLintTests, TB10)",
		"MachmanKit/Sources/MachmanCore/SSHDiscovery.swift":
			"no TCP probe to a guest without the local-network opt-in (SSHProbeLabTests)",
		"MachmanDesktop/DaemonConnection.swift":
			"its Debug-only daemon handling (pre-dates the lab)",
	]

	@Test("Q18: test-mode seams live only in the inventoried files (TB13)")
	func testModeSeamsLiveOnlyInTheInventoriedFiles() throws {
		let files = Self.productRoots.flatMap(SourceScan.swiftFiles(under:))
		#expect(files.contains("MachmanAgent/MachmanAgentApp.swift"))
		var using: [String: [SourceScan.Hit]] = [:]
		for marker in Self.markers {
			for hit in try SourceScan.hits(marker, in: files) {
				using[hit.file, default: []].append(hit)
			}
		}
		for (file, hits) in using.sorted(by: { $0.key < $1.key })
		where Self.inventory[file] == nil {
			Issue.record("""
				\(file) has a test-mode seam the inventory doesn't list: add it to \
				TestModeSeamInventoryTests.inventory with a Q18 test proving the seam inert \
				for the .dev and Release suites.
				\(hits.map(\.description).joined(separator: "\n"))
				""")
		}
		for file in Self.inventory.keys.sorted() where using[file] == nil {
			Issue.record("\(file) is inventoried but has no test-mode seam: drop it from the list")
		}
	}

	// The scan is only as good as its markers: each finds the seam it stands for.
	@Test("Q18: the seam scan flags each kind of seam (TB13)")
	func theSeamScanFlagsEachKindOfSeam() throws {
		let seams = [
			"guard " + "MachmanTestMode" + ".isActive else { return }",
			"let lab = LabEnvironment" + ".current",
			"func build(lab: LabEnvironment" + "? = .current) {}",
			"try extraFiles(for: config, lab" + ": .current)",
			"LabAnswers" + ".answerIfTesting(prompt)",
			"environment[\"MACHMAN_" + "LAB_ANSWERS\"]",
			"#if " + "DEBUG",
		]
		for (seam, marker) in zip(seams, Self.markers) {
			#expect(SourceScan.code(seam).contains(try Regex(marker)), "\(seam)")
		}
		let comment = "// reads MACHMAN_" + "LAB_DEVICES"
		#expect(!SourceScan.code(comment).contains(try Regex("MACHMAN_")))
	}
}
