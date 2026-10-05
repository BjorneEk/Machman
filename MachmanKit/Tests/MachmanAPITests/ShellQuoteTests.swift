//
//  ShellQuoteTests.swift
//  MachmanAPITests
//
//  C26: the commands Machman shows to copy wrapped paths that carry the VM's name in bare
//  single quotes, so an apostrophe opened an unterminated quote and a crafted name ran in
//  the user's shell. Each value goes through sh here and must come back as one word,
//  byte for byte, with nothing else run.
//

import Testing
import Foundation
import MachmanAPI
import MachmanTestSupport

struct ShellQuoteTests {
	@Test func aPlainValueIsWrappedAndAnApostropheEscaped() {
		#expect(ShellQuote.single("/vms/Debian/share") == "'/vms/Debian/share'")
		#expect(ShellQuote.single("Bob's") == #"'Bob'\''s'"#)
		#expect(ShellQuote.single("") == "''")
	}

	@Test func everyValueReachesTheShellAsOneWord() async throws {
		let directory = TestEnvironment.scratchURL
			.appendingPathComponent("shellquote-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let values = [
			"/Users/demo/VMs/Bob's Ubuntu/ssh/id_ed25519",
			"x'; touch PWNED; '",
			"a && touch PWNED",
			"$(touch PWNED) `touch PWNED` $HOME \\ \" * ?",
			"''",
			"tab\there",
		]
		for value in values {
			let sh = try await Subprocess.run(
				"/bin/sh", ["-c", "printf '%s|' " + ShellQuote.single(value) + " end"],
				directory: directory)
			#expect(sh.status == 0)
			#expect(sh.output == value + "|end|", "\(value)")
		}
		#expect(!FileManager.default.fileExists(
			atPath: directory.appendingPathComponent("PWNED").path))
	}
}
