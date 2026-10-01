//
//  SSHAliasFormTests.swift
//  MachmanDesktopCoreTests
//
//  The SSH inspector's alias field sent every draft and left the refusal to a daemon
//  alert. A draft the alias rule refuses, or one another VM already answers to, is now
//  explained under the field and never sent.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanDesktopCore

@MainActor
struct SSHAliasFormTests {
	@Test func anUnusableAliasIsExplainedAndNotSent() async throws {
		let h = await DesktopHarness.make()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		let problem = h.viewModel.sshAliasProblem("dev box", for: debian)
		#expect(problem != nil)
		#expect(problem == SSHAliasRule.problem("dev box"))
		#expect(!h.viewModel.submitSSHAlias(debian, draft: "dev box"))
		try await Task.sleep(for: .milliseconds(50))
		#expect(!h.stub.calls.contains("setSSH"))
	}

	@Test func anAliasAnotherVMUsesIsExplained() async throws {
		let h = await DesktopHarness.make()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		#expect(h.viewModel.sshAliasProblem("fedora.machman", for: debian)
			== "Fedora already answers to \u{201C}fedora.machman\u{201D}")
		// Its own alias is no conflict.
		#expect(h.viewModel.sshAliasProblem("debian.machman", for: debian) == nil)
	}

	@Test func aGoodAliasIsTrimmedAndSent() async throws {
		let h = await DesktopHarness.make()
		let debian = try #require(h.viewModel.vms.first { $0.name == "Debian" })
		#expect(h.viewModel.sshAliasProblem("", for: debian) == nil)   // reset to default
		#expect(h.viewModel.submitSSHAlias(debian, draft: " dev "))
		#expect(await eventually { h.stub.vms["Debian"]?.ssh?.alias == "dev" })
	}
}
