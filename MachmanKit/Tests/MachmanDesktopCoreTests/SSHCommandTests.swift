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

	// C28: the session tab's paths went to ssh unescaped. A VM named with "%" made ssh die
	// ("percent_dollar_expand: failed": the path options expand %-tokens, -i too) and one
	// with a double quote made it refuse the option — so its SSH tabs never connected.
	@Test func pathsWithPercentSignsAndQuotesReachSSHIntact() async throws {
		let dir = #"/vms/50% off "x"/ssh/"#
		var vm = pinned(alias: "x.machman")
		vm.ssh?.identityFilePath = dir + "id_ed25519"
		vm.ssh?.knownHostsPath = dir + "known_hosts"
		let arguments = try #require(SSHCommand.arguments(for: vm))
		#expect(arguments.contains(#"IdentityFile="/vms/50%% off \"x\"/ssh/id_ed25519""#))
		#expect(arguments.contains(#"UserKnownHostsFile="/vms/50%% off \"x\"/ssh/known_hosts""#))
		guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh") else { return }

		// ssh -G resolves the options it was given and exits without connecting. It prints
		// IdentityFile as written (its tokens expand when the key loads, as in the managed
		// ~/.ssh file) and UserKnownHostsFile expanded.
		let ssh = try await Subprocess.run(
			"/usr/bin/ssh", ["-G", "-F", "/dev/null"] + arguments.dropLast() + ["x.invalid"])
		#expect(ssh.status == 0, "\(ssh.output)")
		#expect(ssh.output.contains(#"identityfile /vms/50%% off "x"/ssh/id_ed25519"#))
		#expect(ssh.output.contains("userknownhostsfile " + dir + "known_hosts"))
	}

	@Test func theShellLineDoublesAPercentSign() throws {
		var vm = Samples.linuxApostropheName("50% off")
		vm.ssh?.identityFilePath = "/vms/50% off/ssh/id_ed25519"
		#expect(SSHCommand.shellLine(for: vm)
			== "ssh -i '/vms/50%% off/ssh/id_ed25519' -o IdentitiesOnly=yes demo@192.168.64.7")
	}

	// Review F2: ssh expands ${VAR} in -i and in IdentityFile with no escape — a VM named
	// x${NOPE} (stored before names refused it) made ssh die, or read another file when the
	// variable was set. Such a VM gets no session tab and no copied line.
	@Test func aKeyPathHoldingADollarBraceGivesNoCommand() {
		var vm = pinned(alias: "x.machman")
		vm.ssh?.identityFilePath = "/vms/x${NOPE}/ssh/id_ed25519"
		vm.ssh?.knownHostsPath = "/vms/x${NOPE}/ssh/known_hosts"
		#expect(SSHCommand.arguments(for: vm) == nil)
		#expect(SSHCommand.shellLine(for: vm) == nil)
	}

	// A legacy name with a line break can't be quoted: -i takes it raw, "%" doubled.
	@Test func aKeyPathWithALineBreakGoesInRaw() throws {
		var vm = pinned(alias: "x.machman")
		vm.ssh?.identityFilePath = "/vms/a\nb 50% off/ssh/id_ed25519"
		let arguments = try #require(SSHCommand.arguments(for: vm))
		#expect(Array(arguments.prefix(2)) == ["-i", "/vms/a\nb 50%% off/ssh/id_ed25519"])
	}
}
