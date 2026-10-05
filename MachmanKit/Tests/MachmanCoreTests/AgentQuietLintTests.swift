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
	// Written as escaped patterns, and the provoked calls below in pieces, so this file never
	// spells a call it bans (nor one the test sources' own host-quiet lint bans).
	static let alertPatterns = [#"NSAlert\("#, #"runModal"#]
	static let frontPatterns = [
		#"\.activate\((ignoringOtherApps|options|\))"#,
		#"setActivationPolicy\(\.(regular|accessory)\)"#,
		#"requestUserAttention"#,
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

	// A MenuBarExtra makes an NSStatusItem even when it isn't inserted, and AppKit saves the
	// item's visibility into the agent's preferences: the dev agent's own domain, which the lab
	// agent shares. So under a test suite the agent builds no scene at all: its entry point
	// asks test mode before it runs the SwiftUI app, the app alone holds the MenuBarExtra, and
	// nothing in the agent makes a status item of its own.
	@Test("Q18: under a test suite the agent builds no menu-bar scene or status item (TB10)")
	func underATestSuiteTheAgentBuildsNoMenuBarSceneOrStatusItem() throws {
		let agent = SourceScan.swiftFiles(under: "MachmanAgent")
		let file = "MachmanAgent/MachmanAgentApp.swift"
		#expect(agent.contains(file))
		let statusItems = try SourceScan.hits(#"NSStatus(Bar|Item)"#, in: agent)
		#expect(statusItems.isEmpty, "\(statusItems)")
		let code = try SourceScan.lines(of: file).map(SourceScan.code)
		// A declaration's lines: from the line that holds it to its closing brace, the first
		// later line that is a lone `}` at the declaration's indentation.
		func body(of declaration: String) throws -> Range<Int> {
			let start = try #require(code.firstIndex { $0.contains(declaration) }, "\(declaration)")
			let indent = code[start].prefix { $0 == "\t" }
			let end = code[start...].firstIndex { $0 == indent + "}" } ?? code.endIndex
			return start..<end
		}
		let app = try body(of: "struct MachmanAgentApp: App {")
		let extras = try SourceScan.hits(#"MenuBarExtra\("#, in: agent)
		#expect(!extras.isEmpty)
		for hit in extras {
			#expect(hit.file == file && app.contains(hit.line - 1), "\(hit)")
		}
		let mains = code.indices.filter { code[$0].contains("@main") }
		let entry = try body(of: "enum MachmanAgentMain {")
		#expect(mains == [entry.lowerBound - 1], "the one @main is the entry point")
		let dispatch = try Regex(#"if MachmanTestMode\.isActive \{\s*"#
			+ #"MachmanAgentDelegate\.runWithoutScenes\(\)\s*"#
			+ #"\} else \{\s*MachmanAgentApp\.main\(\)"#)
		#expect(code[entry].joined(separator: "\n").contains(dispatch),
			"main runs the SwiftUI app only outside test mode")
		let sceneless = code[try body(of: "static func runWithoutScenes() {")]
		#expect(!sceneless.contains {
			$0.contains("MachmanAgentApp") || $0.contains("MenuBarExtra")
		})
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
			"NSApp" + ".activate(ignoringOtherApps: true)", "NSApp" + ".activate()",
			"NSRunningApplication.current.activate" + "(options: [])",
			"NSApp.setActivationPolicy(.reg" + "ular)", "app.setActivationPolicy(.acc" + "essory)",
			"NSApp.requestUserAttention" + "(.criticalRequest)",
		]
		for line in provoked {
			let flagged = try (Self.alertPatterns + Self.frontPatterns)
				.contains { SourceScan.code(line).contains(try Regex($0)) }
			#expect(flagged, "\(line)")
		}
		let tabs = SourceScan.code("panes[i].activate(tab)")
		#expect(!tabs.contains(try Regex(Self.frontPatterns[0])))
		#expect(!SourceScan.code("NSApp.setActivationPolicy(.prohibited)")
			.contains(try Regex(Self.frontPatterns[1])))
		#expect(!SourceScan.code("// alert.runModal" + "()").contains(try Regex("runModal")))
	}
}
