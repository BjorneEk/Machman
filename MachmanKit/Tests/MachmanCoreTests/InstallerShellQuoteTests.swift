//
//  InstallerShellQuoteTests.swift
//  MachmanTests
//
//  The installer's machman.env quoting and the copied commands' quoting are one rule
//  (ShellQuote.single, C26): the same tricky values give the same bytes from both.
//

import Testing
import Foundation
import MachmanAPI
@testable import MachmanCore

struct InstallerShellQuoteTests {
	@Test func theInstallerQuotesExactlyLikeTheSharedRule() {
		let table: [(value: String, quoted: String)] = [
			("", "''"),
			("/vms/Debian/share", "'/vms/Debian/share'"),
			("Bob's Ubuntu", #"'Bob'\''s Ubuntu'"#),
			("x'; rm -rf ~; '", #"'x'\''; rm -rf ~; '\'''"#),
			("a && b", "'a && b'"),
			("$(touch x) `y` $HOME", "'$(touch x) `y` $HOME'"),
			(#"\ " * ?"#, #"'\ " * ?'"#),
			("''", #"''\'''\'''"#),
			("tab\there\nline", "'tab\there\nline'"),
			("café ✓", "'café ✓'"),
		]
		for row in table {
			#expect(ShellQuote.single(row.value) == row.quoted, "\(row.value)")
			#expect(GuestInstallerWriter.shellQuoted(row.value) == row.quoted, "\(row.value)")
		}
	}
}
