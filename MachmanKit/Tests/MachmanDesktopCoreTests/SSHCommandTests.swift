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
import MachmanTestSupport
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

	// C26: the SSH inspector's line, pasted into a shell, carries the key path as ONE word
	// even when the VM's name holds an apostrophe (it opened an unterminated quote).
	@Test func theShellLineKeepsAnApostropheNamesKeyPathWhole() async throws {
		let vm = Samples.linuxApostropheName()
		let line = try #require(SSHCommand.shellLine(for: vm))
		let identity = try #require(vm.ssh?.identityFilePath)
		#expect(identity.contains("Bob's Ubuntu"))

		// sh runs the pasted line with a stand-in ssh that prints its arguments.
		let sh = try await Subprocess.run(
			"/bin/sh", ["-c", #"ssh() { printf '%s\n' "$@"; }; "# + line])
		#expect(sh.status == 0)
		#expect(sh.output.split(separator: "\n").map(String.init)
			== ["-i", identity, "-o", "IdentitiesOnly=yes", "demo@192.168.64.7"])
	}
}
