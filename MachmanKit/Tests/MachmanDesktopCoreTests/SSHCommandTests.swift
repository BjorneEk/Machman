//
//  SSHCommandTests.swift
//  MachmanDesktopCoreTests
//
//  C13, the tab half: an SSH tab pins the guest under the alias its known_hosts file is
//  keyed by. The fallback for a daemon that serves no alias used the bare VM name, which
//  for "Debian copy" is two words to ssh and never matches the pin.
//

import Testing
import Foundation
import MachmanAPI
import MachmanFixtures
@testable import MachmanDesktopCore

struct SSHCommandTests {
	private func pinned(alias: String?) -> VMInfo {
		var vm = Samples.linux("Debian copy", state: .running)
		vm.ssh?.alias = alias
		vm.ssh?.identityFilePath = "/x/id"
		vm.ssh?.guestHostKey = "ssh-ed25519 AAAA"
		vm.ssh?.knownHostsPath = "/x/kh"
		return vm
	}

	@Test func aSpacedNameWithoutAServedAliasPinsTheMappedOne() throws {
		let arguments = try #require(SSHCommand.arguments(for: pinned(alias: nil)))
		#expect(arguments.contains("HostKeyAlias=Debian-copy.machman"))
		#expect(arguments.contains("StrictHostKeyChecking=yes"))
		#expect(arguments.last == "demo@192.168.64.7")
	}

	@Test func aServedAliasIsUsedAsIs() throws {
		let arguments = try #require(SSHCommand.arguments(for: pinned(alias: "dev")))
		#expect(arguments.contains("HostKeyAlias=dev"))
	}

	@Test func aRawServedAliasIsMapped() throws {
		let arguments = try #require(
			SSHCommand.arguments(for: pinned(alias: "Debian copy.machman")))
		#expect(arguments.contains("HostKeyAlias=Debian-copy.machman"))
	}
}
