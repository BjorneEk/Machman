//
//  TestPassesTests.swift
//  MachmanDesktopCoreTests
//
//  Q41: one swift test process shares one main actor, and the engine suites' @MainActor tests
//  hold it for whole seconds under load (a subprocess, a fork, a big map, a fsync on the main
//  actor). This suite's waits on main-actor work ran out behind them while its own work took
//  milliseconds, so scripts/test.sh runs it in a swift test pass of its own.
//

import Testing
import Foundation
import MachmanTestSupport

struct TestPassesTests {
	// The run_pass lines of an unfiltered run: the else branch after `if ((filtered))`.
	private func unfilteredPasses() throws -> [String] {
		let lines = try RepoFiles.text("scripts/test.sh").components(separatedBy: "\n")
		let start = try #require(lines.firstIndex { $0.hasPrefix("if ((filtered)); then") })
		let branch = try #require(lines[start...].firstIndex { $0 == "else" })
		let end = try #require(lines[branch...].firstIndex { $0 == "fi" })
		return lines[branch..<end].map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { $0.hasPrefix("run_pass ") }
	}

	@Test("Q41: test.sh runs MachmanDesktopCoreTests in a swift test pass of its own")
	func theDesktopCoreSuiteRunsInAPassOfItsOwn() throws {
		let script = try RepoFiles.text("scripts/test.sh")
		#expect(script.contains("core='MachmanDesktopCoreTests\\.'"))
		#expect(script.contains("ui='MachmanDesktopUITests\\.'"))
		let passes = try unfilteredPasses()
		#expect(passes == [
			#"run_pass --skip "$core" --skip "$ui" "$@""#,
			#"run_pass --filter "$core" "$@""#,
			#"run_pass --filter "$ui" "$@""#,
		])
	}
}
