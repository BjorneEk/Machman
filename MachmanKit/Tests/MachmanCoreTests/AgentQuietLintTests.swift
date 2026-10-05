//
//  AgentQuietLintTests.swift
//  MachmanCoreTests
//
//  TB10: under a test suite the menu-bar agent shows nothing — no alert, Dock icon,
//  activation or menu-bar item, and it launches no other app. That holds because every alert
//  it shows goes through PromptAlert (which the lab answers) and its one app launch checks
//  test mode first; these lints keep a new alert, activation or launch from bypassing them.
//  They read the repo's sources (the worktree this test was built from) and write nothing.
//

import Testing
import Foundation
import MachmanTestSupport

struct AgentQuietLintTests {
	// Written as escaped patterns, so this file never spells the calls it bans.
	static let alertPatterns = [#"NSAlert\("#, #"runModal"#]
	static let frontPatterns = [
		#"activate\(ignoringOtherApps"#, #"setActivationPolicy\(\.(regular|accessory)\)"#,
	]

	@Test("Q18: the agent shows no alert, Dock icon or activation of its own (TB10)")
	func theAgentShowsNoAlertDockIconOrActivationOfItsOwn() throws {
		let agent = SourceScan.swiftFiles(under: "MachmanAgent")
		#expect(agent.contains("MachmanAgent/MachmanAgentApp.swift"))
		for pattern in Self.alertPatterns + Self.frontPatterns {
			let found = try SourceScan.hits(pattern, in: agent)
			#expect(found.isEmpty, "use PromptAlert: \(found)")
		}
		// Its one launch of another app (Open Machman) is recorded, never performed, under a
		// test suite: the function holding the launch checks test mode.
		var launches = 0
		for file in agent {
			let lines = try SourceScan.lines(of: file)
			for (index, line) in lines.enumerated()
			where SourceScan.code(line).contains(try Regex(#"openApplication\("#)) {
				launches += 1
				let start = lines[...index].lastIndex { $0.contains("func ") } ?? 0
				let body = lines[start...index].map(SourceScan.code).joined(separator: "\n")
				#expect(body.contains("MachmanTestMode.isActive"),
					"\(file):\(index + 1) launches an app without checking test mode first")
			}
		}
		#expect(launches > 0)
	}

	@Test("Q18: every AppKit alert in MachmanUI goes through PromptAlert (TB10)")
	func everyAppKitAlertInMachmanUIGoesThroughPromptAlert() throws {
		let ui = SourceScan.swiftFiles(under: "MachmanKit/Sources/MachmanUI")
		#expect(ui.contains("MachmanKit/Sources/MachmanUI/PromptAlert.swift"))
		for pattern in Self.alertPatterns + Self.frontPatterns {
			let found = try SourceScan.hits(pattern, in: ui)
				.filter { $0.file != "MachmanKit/Sources/MachmanUI/PromptAlert.swift" }
			#expect(found.isEmpty, "use PromptAlert: \(found)")
		}
	}

	// The lint is only as good as its patterns: they find the calls they ban.
	@Test("Q18: the agent lints flag a provoked alert and activation (TB10)")
	func theAgentLintsFlagAProvokedCall() throws {
		let provoked = [
			"let alert = NSAlert" + "()", "alert.runModal" + "()",
			"NSApp.activate(ignoringOtherApps" + ": true)",
			"NSApp.setActivationPolicy(.reg" + "ular)", "app.setActivationPolicy(.acc" + "essory)",
		]
		for line in provoked {
			let flagged = try (Self.alertPatterns + Self.frontPatterns)
				.contains { SourceScan.code(line).contains(try Regex($0)) }
			#expect(flagged, "\(line)")
		}
		#expect(!SourceScan.code("NSApp.setActivationPolicy(.prohibited)")
			.contains(try Regex(Self.frontPatterns[1])))
		#expect(!SourceScan.code("// alert.runModal" + "()").contains(try Regex("runModal")))
	}
}
