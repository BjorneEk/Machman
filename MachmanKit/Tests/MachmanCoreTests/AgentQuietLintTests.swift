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
	// MachmanKit/Tests/MachmanCoreTests/<this file> → the repo.
	static let repo = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent().deletingLastPathComponent()
		.deletingLastPathComponent().deletingLastPathComponent()

	struct Hit: CustomStringConvertible {
		let file: String
		let line: Int
		let text: String
		var description: String { "\(file):\(line): \(text)" }
	}

	// Swift files under `directory` (repo-relative), recursively, sorted.
	static func swiftFiles(under directory: String) -> [String] {
		let root = repo.appendingPathComponent(directory)
		let found = FileManager.default.enumerator(atPath: root.path)?
			.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") } ?? []
		return found.sorted().map { directory + "/" + $0 }
	}

	static func lines(of file: String) throws -> [String] {
		try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
			.components(separatedBy: "\n")
	}

	// The code part of a line: anything after `//` is a comment.
	static func code(_ line: String) -> String {
		line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
	}

	// Lines of `files` whose code matches `pattern`.
	static func hits(_ pattern: String, in files: [String]) throws -> [Hit] {
		let regex = try Regex(pattern)
		var found: [Hit] = []
		for file in files {
			for (index, line) in try lines(of: file).enumerated()
			where code(line).contains(regex) {
				found.append(Hit(file: file, line: index + 1, text: line.trimmingCharacters(
					in: .whitespaces)))
			}
		}
		return found
	}

	// Written as escaped patterns, so this file never spells the calls it bans.
	static let alertPatterns = [#"NSAlert\("#, #"runModal"#]
	static let frontPatterns = [
		#"activate\(ignoringOtherApps"#, #"setActivationPolicy\(\.(regular|accessory)\)"#,
	]

	@Test("Q18: the agent shows no alert, Dock icon or activation of its own (TB10)")
	func theAgentShowsNoAlertDockIconOrActivationOfItsOwn() throws {
		let agent = Self.swiftFiles(under: "MachmanAgent")
		#expect(agent.contains("MachmanAgent/MachmanAgentApp.swift"))
		for pattern in Self.alertPatterns + Self.frontPatterns {
			let found = try Self.hits(pattern, in: agent)
			#expect(found.isEmpty, "use PromptAlert: \(found)")
		}
		// Its one launch of another app (Open Machman) is recorded, never performed, under a
		// test suite: the function holding the launch checks test mode.
		var launches = 0
		for file in agent {
			let lines = try Self.lines(of: file)
			for (index, line) in lines.enumerated()
			where Self.code(line).contains(try Regex(#"openApplication\("#)) {
				launches += 1
				let start = lines[...index].lastIndex { $0.contains("func ") } ?? 0
				let body = lines[start...index].map(Self.code).joined(separator: "\n")
				#expect(body.contains("MachmanTestMode.isActive"),
					"\(file):\(index + 1) launches an app without checking test mode first")
			}
		}
		#expect(launches > 0)
	}

	@Test("Q18: every AppKit alert in MachmanUI goes through PromptAlert (TB10)")
	func everyAppKitAlertInMachmanUIGoesThroughPromptAlert() throws {
		let ui = Self.swiftFiles(under: "MachmanKit/Sources/MachmanUI")
		#expect(ui.contains("MachmanKit/Sources/MachmanUI/PromptAlert.swift"))
		for pattern in Self.alertPatterns + Self.frontPatterns {
			let found = try Self.hits(pattern, in: ui)
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
				.contains { Self.code(line).contains(try Regex($0)) }
			#expect(flagged, "\(line)")
		}
		#expect(!Self.code("NSApp.setActivationPolicy(.prohibited)")
			.contains(try Regex(Self.frontPatterns[1])))
		#expect(!Self.code("// alert.runModal" + "()").contains(try Regex("runModal")))
	}
}
