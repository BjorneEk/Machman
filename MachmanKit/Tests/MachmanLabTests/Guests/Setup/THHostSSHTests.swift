//
//  THHostSSHTests.swift
//  MachmanLabTests
//
//  L3 — the Mac-side ssh commands Machman offers (the managed ~/.ssh alias, the session tab's
//  argv, the inspector's copied line) logging into a Debian guest. They open TCP from this
//  process to the guest's address on the VM network, which macOS's Local Network privacy may
//  prompt about: they run only with MACHMAN_LAB_LOCAL_NETWORK=1 (B-1: "nothing with
//  prompts" — never set in wave r3t), and skip with that reason otherwise. Every ssh is
//  sandboxed: TFSSH's host-quiet prefix first (-F /dev/null, no agent, no control socket, no
//  host-key updates), no askpass, HOME the scope's, known_hosts in the run.
//

import Foundation
import MachmanAPI
import MachmanDesktopCore
import MachmanTestSupport
import Testing

enum THHostSSH {
	/// Whether host→guest TCP is allowed in this run.
	static var allowed: Bool { Lab.environment["MACHMAN_LAB_LOCAL_NETWORK"] == "1" }

	static let skip = "Deferred: local network (opt-in MACHMAN_LAB_LOCAL_NETWORK=1)"

	/// The test's own options, after the product's argv (ssh takes the first value of an option
	/// on its command line, so the product's win) and before the destination.
	/// TFSSH.hostQuietPrefix goes before the product's argv: ssh reads ~/.ssh/config through
	/// getpwuid, whatever HOME says, so only its -F /dev/null keeps the user's config
	/// (ControlMaster, Include, ProxyCommand) out; a product -F after it still wins (ssh keeps
	/// the last -F). A config file loses to every command-line option, though: a run through
	/// the managed config (`viaConfig`) leaves its pin file (the scope's) to it, and insists
	/// on that pin: a config that fell back to accept-new would learn the key, and pass.
	static func sandbox(_ agent: LabAgent, viaConfig: Bool = false) throws -> [String] {
		let known = try TH.hostDir(agent, "ssh") + "/known_hosts"
		let pins = viaConfig ? ["-o", "StrictHostKeyChecking=yes"] : [
			"-o", "UserKnownHostsFile=\(known)", "-o", "StrictHostKeyChecking=accept-new",
		]
		return ["-o", "BatchMode=yes"] + pins + ["-o", "ConnectTimeout=10"]
	}

	static func environment(_ agent: LabAgent) -> [String: String] {
		["HOME": agent.scope.homeDir, "PATH": "/usr/bin:/bin"]
	}

	/// /usr/bin/ssh with the host-quiet prefix, then `argv` with the sandbox options before its
	/// last word (the destination or, with a command, the word before it).
	static func run(
		_ agent: LabAgent, _ argv: [String], command: String = "true", viaConfig: Bool = false
	) async throws -> Subprocess.Result {
		var arguments = argv
		let destination = arguments.removeLast()
		arguments = TFSSH.hostQuietPrefix + arguments
			+ (try sandbox(agent, viaConfig: viaConfig)) + [destination, command]
		return try await Subprocess.run(
			"/usr/bin/ssh", arguments, environment: environment(agent), timeout: 60)
	}

	/// A pasted line, unchanged, by zsh -f; its ssh is a PATH-first shim that adds the
	/// host-quiet prefix and the sandbox options. stdin answers "echo TH-OK; exit".
	static func runPasted(_ agent: LabAgent, _ line: String) async throws -> Subprocess.Result {
		let dir = try TH.hostDir(agent, "shim")
		let options = try (TFSSH.hostQuietPrefix + sandbox(agent)).map(ShellQuote.single)
			.joined(separator: " ")
		try "#!/bin/sh\nexec /usr/bin/ssh \(options) \"$@\"\n"
			.write(toFile: dir + "/ssh", atomically: true, encoding: .utf8)
		chmod(dir + "/ssh", 0o755)
		let script = "printf 'echo TH-OK; exit\\n' | \(line)"
		return try await Subprocess.run(
			"/bin/zsh", ["-f", "-c", script],
			environment: ["HOME": agent.scope.homeDir, "PATH": dir + ":/usr/bin:/bin"],
			timeout: 60)
	}

	/// The guest set up for SSH as lab, and the agent's readiness probe through.
	static func ready(_ g: any THGuest) async throws -> VMInfo {
		let run = try await g.install("-y --ssh", user: "lab", escalation: .sudo)
		#expect(run.status == 0, "\(run.output)")
		let deadline = ContinuousClock.now + .seconds(180)
		while true {
			let info = try await g.vm.info()
			if info.ssh?.address != nil, info.ssh?.reachability == .ready { return info }
			if ContinuousClock.now >= deadline {
				throw LabError.stateTimeout(
					vm: g.vm.name, wanted: "SSH ready",
					last: "\(String(describing: info.ssh?.reachability))")
			}
			try await Task.sleep(for: .seconds(2))
		}
	}

	static func named(_ name: String) -> THGuestOptions {
		var options = THGuestOptions()
		options.name = name
		return options
	}
}

// L3 — Mac→guest ssh into Debian under VZ (opt-in: Local Network).
@Suite(
	"L3 Guest Setup — Mac-side ssh", .serialized, .enabled(if: Lab.runs(.l3)),
	.enabled(if: THHostSSH.allowed, Comment(rawValue: THHostSSH.skip)))
struct THHostSSHTests {
	@Test("A1b: ssh dev logs into the Debian guest")
	func aliasLogsIn() async throws {
		try await TH.withGuest(.debian) { g in
			_ = try await THHostSSH.ready(g)
			_ = try await g.agent.api.setSSH(
				vm: g.vm.name, integrationEnabled: true, reverseApproved: nil, alias: "dev")
			let config = g.agent.scope.homeDir + "/.ssh/machman/config"
			let known = try TH.hostDir(g.agent, "ssh") + "/known_hosts"
			let before = (try? String(contentsOfFile: known, encoding: .utf8)) ?? ""
			let ssh = try await THHostSSH.run(g.agent, ["-F", config, "dev"], viaConfig: true)
			#expect(ssh.status == 0, "\(ssh.output)")
			let after = (try? String(contentsOfFile: known, encoding: .utf8)) ?? ""
			#expect(after == before, "the managed pin answered, no key was learned")
		}
	}

	@Test("W1-1b: ssh dev-copy.machman logs into the Debian guest")
	func defaultAliasLogsIn() async throws {
		try await TH.withGuest(.debian, THHostSSH.named("dev copy")) { g in
			_ = try await THHostSSH.ready(g)
			_ = try await g.agent.api.setSSH(
				vm: g.vm.name, integrationEnabled: true, reverseApproved: nil, alias: nil)
			let config = g.agent.scope.homeDir + "/.ssh/machman/config"
			let ssh = try await THHostSSH.run(
				g.agent, ["-F", config, "dev-copy.machman"], viaConfig: true)
			#expect(ssh.status == 0, "\(ssh.output)")
		}
	}

	@Test("R3W2-11: a session connects after Guest Setup is removed and the VM renamed")
	func sessionAfterRename() async throws {
		try await TH.withGuest(.debian, THHostSSH.named("deb c23")) { g in
			_ = try await THHostSSH.ready(g)
			try await g.check("sync")
			try await g.vm.stop(.force)
			_ = try await g.agent.api.removeDevice(vm: g.vm.name, kind: .guestSetup)
			try await g.vm.rename(to: "deb c23 renamed")
			try await g.vm.start()
			let info = try await THHostSSH.readyAgain(g)
			let argv = try #require(SSHCommand.arguments(for: info))
			#expect(argv.contains("StrictHostKeyChecking=yes"), "\(argv)")
			let ssh = try await THHostSSH.run(g.agent, argv)
			#expect(ssh.status == 0, "\(ssh.output)")
		}
	}

	@Test("R3W2-16: a session connects to a VM renamed 50% off")
	func sessionToPercentName() async throws {
		try await TH.withGuest(.debian) { g in
			_ = try await THHostSSH.ready(g)
			try await g.check("sync")
			try await g.vm.stop(.force)
			try await g.vm.rename(to: "50% off")
			try await g.vm.start()
			let info = try await THHostSSH.readyAgain(g)
			let argv = try #require(SSHCommand.arguments(for: info))
			let ssh = try await THHostSSH.run(g.agent, argv)
			#expect(ssh.status == 0, "\(ssh.output)")
		}
	}

	@Test("R3W2-13: the SSH inspector's command for Bob's Ubuntu runs as copied")
	func pastedLineRuns() async throws {
		try await TH.withGuest(.debian, THHostSSH.named("Bob's Ubuntu")) { g in
			let info = try await THHostSSH.ready(g)
			_ = try await g.agent.api.setSSH(
				vm: g.vm.name, integrationEnabled: false, reverseApproved: nil, alias: nil)
			let line = try #require(SSHCommand.shellLine(for: info))
			let ran = try await THHostSSH.runPasted(g.agent, line)
			#expect(ran.output.contains("TH-OK"), "\(ran.output)")
		}
	}
}

extension THHostSSH {
	/// After a restart: the address rediscovered and the probe through again.
	static func readyAgain(_ g: any THGuest) async throws -> VMInfo {
		let deadline = ContinuousClock.now + .seconds(240)
		while true {
			let info = try await g.vm.info()
			if info.ssh?.address != nil, info.ssh?.reachability == .ready { return info }
			if ContinuousClock.now >= deadline {
				throw LabError.stateTimeout(vm: g.vm.name, wanted: "SSH ready", last: "not yet")
			}
			try await Task.sleep(for: .seconds(2))
		}
	}
}
