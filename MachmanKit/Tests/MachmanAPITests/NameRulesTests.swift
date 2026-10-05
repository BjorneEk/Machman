//
//  NameRulesTests.swift
//  MachmanAPITests
//
//  The identifier rules both the daemon and the desktop forms apply (PR8): what each kind
//  refuses and in which words, the trim-then-validate entry, cleaned suggestions for names
//  the user didn't type, the default ssh alias mapping, and the shapes of guest claims.
//

import Testing
import Foundation
import MachmanAPI

struct NameRulesTests {

	@Test func vmNamesRefuseWhatBreaksADirectory() {
		let rule = NameRule.vmName
		#expect(rule.problem("") == "A VM name can’t be empty")
		#expect(rule.problem(" x") == "A VM name can’t start or end with a space")
		#expect(rule.problem("x ") == "A VM name can’t start or end with a space")
		#expect(rule.problem(".x") == "A VM name can’t start with a dot")
		#expect(rule.problem("..") == "A VM name can’t start with a dot")
		#expect(rule.problem("a/b") == "A VM name can’t contain \u{201C}/\u{201D}")
		let control = "A VM name can’t contain tabs, line breaks or other control characters"
		#expect(rule.problem("a\tb") == control)
		#expect(rule.problem("a\nb") == control)
		#expect(rule.problem("a\u{2028}b") == control)
		#expect(rule.problem(String(repeating: "x", count: 256)) == "A VM name is too long")
		for fine in ["dev copy", "Größe", "🐧 Linux", "a:b", "50%off",
			String(repeating: "x", count: 255)] {
			#expect(rule.problem(fine) == nil, "\(fine) should pass")
		}
	}

	@Test func mountTagsAlsoFollowTheShareNameRules() throws {
		let rule = NameRule.mountTag
		for c in [":", "\\", "*", "?", "|", "<", ">"] {
			#expect(rule.problem("a\(c)b") == "A mount tag can’t contain \u{201C}\(c)\u{201D}")
		}
		for reserved in ReservedShareNames.all {
			#expect(rule.problem(reserved) == "\u{201C}\(reserved)\u{201D} is reserved by Machman")
			let error = try #require(throws: MachmanError.self) { try rule.validate(reserved) }
			#expect(error.code == .alreadyExists)
		}
		let error = try #require(throws: MachmanError.self) { try rule.validate("a/b") }
		#expect(error.code == .invalidArgument)
		for fine in ["my docs", "a[b]", "日本語", "~x"] {
			#expect(rule.problem(fine) == nil, "\(fine) should pass")
		}
	}

	@Test func diskNamesLeaveRoomForTheExtension() {
		#expect(NameRule.diskName.problem(String(repeating: "d", count: 252))
			== "A disk name is too long")
		#expect(NameRule.diskName.problem(String(repeating: "d", count: 251)) == nil)
		#expect(NameRule.kernelTag.problem(".x") == "A kernel tag can’t start with a dot")
	}

	@Test func normalizedTrimsThenValidates() throws {
		for rule in [NameRule.vmName, .diskName, .mountTag, .kernelTag] {
			#expect(try rule.normalized("  data ") == "data")
			#expect(throws: MachmanError.self) { try rule.normalized("   ") }
		}
	}

	@Test func suggestionsCleanNamesTheUserDidNotType() {
		#expect(NameRule.mountTag.suggestion(from: ".config", fallback: "share") == "config")
		#expect(NameRule.mountTag.suggestion(from: "a:b", fallback: "share") == "a-b")
		#expect(NameRule.mountTag.suggestion(from: "...", fallback: "share") == "share")
		#expect(NameRule.mountTag.suggestion(from: "GuestSetup", fallback: "share") == "share")
		#expect(NameRule.mountTag.suggestion(from: "docs", fallback: "share") == "docs")
		#expect(NameRule.diskName.suggestion(from: ".hidden", fallback: "disk") == "hidden")
		#expect(NameRule.diskName.suggestion(from: "a\tb", fallback: "disk") == "a-b")
		let long = NameRule.diskName.suggestion(
			from: String(repeating: "é", count: 200), fallback: "disk")
		#expect(long.utf8.count <= 251 && !long.isEmpty)
	}

	@Test func aliasesKeepTheirRules() throws {
		for bad in ["dev *", "dev?", "-dev", "de v", "a/b", "#dev", "dev\"", "",
			String(repeating: "a", count: 65)] {
			#expect(throws: MachmanError.self, "\(bad) should be refused") {
				try SSHAliasRule.validate(bad)
			}
		}
		#expect(SSHAliasRule.problem(String(repeating: "a", count: 65))
			== "An SSH alias can be at most 64 characters")
		#expect(SSHAliasRule.problem("de v") == "An SSH alias must start with a letter or "
			+ "digit and use only letters, digits, dots, dashes and underscores")
		#expect(SSHAliasRule.problem("dev") == nil)
		#expect(SSHAliasRule.isWellFormed(String(repeating: "a", count: 100)))
	}

	@Test func defaultAliasesMapIntoTheAliasCharset() {
		let table = [
			"dev copy": "dev-copy.machman",
			"Debian": "Debian.machman",
			"Debian kept": "Debian-kept.machman",
			"test-": "test-.machman",
			"café": "cafe.machman",
			"(test)": "test.machman",
			"50%off": "50-off.machman",
			"日本語": "vm-805f5ce7.machman",
		]
		for (name, alias) in table {
			#expect(SSHAliasRule.defaultAlias(for: name) == alias, "\(name)")
		}
		for name in Array(table.keys) + [".hidden", "a\"b", "🐧 Linux", "x\ty", "-", "..."] {
			let alias = SSHAliasRule.defaultAlias(for: name)
			#expect(SSHAliasRule.isWellFormed(alias), "\(name) → \(alias)")
		}
	}

	@Test func guestClaimsMustHaveTheirShape() {
		for user in ["admin", "a.b_c-d", "root"] {
			#expect(GuestValueRule.isUserName(user), "\(user)")
		}
		for user in ["", "-x", "a b", "$(x)", "ü", "a\nb"] {
			#expect(!GuestValueRule.isUserName(user), "\(user)")
		}
		for address in ["192.168.64.9", "fe80::1", "::1"] {
			#expect(GuestValueRule.isAddress(address), "\(address)")
		}
		for address in ["10.0.0.1%en0", "evil.example", "1.2.3", "x y", "", "fe80::1%en0"] {
			#expect(!GuestValueRule.isAddress(address), "\(address)")
		}
		for key in ["ssh-ed25519 AAAAC3Nz host", "sk-ssh-ed25519@openssh.com AAAA",
			"ecdsa-sha2-nistp256 AAAAE2Vj+/9= comment with spaces"] {
			#expect(GuestValueRule.isPublicKeyLine(key), "\(key)")
		}
		for key in ["command=\"x\" ssh-ed25519 AAAA", "ssh-ed25519", "@revoked x",
			"ssh-ed25519 AA\u{7}", "ssh-ed25519\tAAAA", "ssh-ed25519 AA$A"] {
			#expect(!GuestValueRule.isPublicKeyLine(key), "\(key)")
		}
	}

	// Review F2: ssh expands ${VAR} in the key and pin paths a VM's name ends up in, with no
	// escape, so a VM named x${y} got ssh paths that broke or silently moved. New names refuse
	// it; "$" and braces alone stay fine, and other kinds are not affected.
	@Test func vmNamesRefuseADollarBrace() {
		#expect(NameRule.vmName.problem("x${y}") == "A VM name can’t contain \u{201C}${\u{201D}")
		#expect(NameRule.vmName.problem("${HOME}") == "A VM name can’t contain \u{201C}${\u{201D}")
		for fine in ["x$y", "x{y}", "$5 {x}", "a$ {b}"] {
			#expect(NameRule.vmName.problem(fine) == nil, "\(fine) should pass")
		}
		#expect(NameRule.diskName.problem("x${y}") == nil)
		#expect(SSHConfigQuote.argument("/vms/x${y}/id", expandsTokens: true) == nil)
		#expect(SSHConfigQuote.argument("x${y}", expandsTokens: false) == #""x${y}""#)
	}
}
