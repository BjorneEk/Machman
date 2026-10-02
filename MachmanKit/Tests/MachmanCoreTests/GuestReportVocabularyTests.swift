//
//  GuestReportVocabularyTests.swift
//  MachmanTests
//
//  A14: the guest report's console login states and run statuses are named once, in
//  MachmanAPI (GuestConsoleLogin, GuestRunStatus), and the host's parser and the inspectors
//  use those names. These tests hold the names to what the shipped script actually prints,
//  so the two ends can't drift: a word the script gains or loses fails here.
//

import Testing
import Foundation
import MachmanTestSupport
import MachmanAPI
@testable import MachmanCore

struct GuestReportVocabularyTests {
	private var script: String { GuestSetupScript.assembled.text }

	// The body of a top-level `name() {` … `}` function in the assembled script.
	private func function(_ name: String) -> String? {
		guard let start = script.range(of: "\n\(name)() {\n"),
			let end = script.range(of: "\n}\n", range: start.upperBound..<script.endIndex)
		else { return nil }
		return String(script[start.upperBound..<end.lowerBound])
	}

	private func matches(_ pattern: String, in text: String) throws -> Set<String> {
		let regex = try NSRegularExpression(pattern: pattern)
		let range = NSRange(text.startIndex..., in: text)
		return Set(regex.matches(in: text, range: range).compactMap {
			Range($0.range(at: 1), in: text).map { String(text[$0]) }
		})
	}

	@Test func theScriptSpeaksOnlyKnownLoginStates() throws {
		let body = try #require(function("console_login_state"))
		let known: Set = [
			GuestConsoleLogin.missing, GuestConsoleLogin.activeAuto, GuestConsoleLogin.active,
			GuestConsoleLogin.configured, GuestConsoleLogin.none,
		]
		#expect(try matches(#"echo ([a-z-]+)"#, in: body) == known)
	}

	@Test func theScriptSpeaksOnlyKnownRunStatuses() throws {
		let known: Set = [GuestRunStatus.ok, GuestRunStatus.partial, GuestRunStatus.failed]
		#expect(try matches(#"_wr_status=([a-z]+)"#, in: script) == known)
	}

	@Test @MainActor func theParserNamesTheAutomaticLogin() throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "vocab")
			let vm = try VMConfig(name: "vocab", memorySize: 1 << 30, cpuCount: 2)
			_ = try GuestReport.parse("""
				SCRIPT_VERSION=5
				STATUS=ok
				CONSOLE_1=hvc0 active auto
				CONSOLE_2=hvc1 configured
				""").apply(to: vm, stampedAt: Date())
			#expect(vm.setup?.consoles.first?.login == GuestConsoleLogin.activeAuto)
			#expect(vm.setup?.consoles.last?.login == GuestConsoleLogin.configured)
			#expect(vm.setup?.lastRunStatus == GuestRunStatus.ok)
		}
	}
}
