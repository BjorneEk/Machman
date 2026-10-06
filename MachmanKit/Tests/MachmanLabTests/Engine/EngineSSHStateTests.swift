//
//  EngineSSHStateTests.swift
//  MachmanLabTests
//
//  L2 — the agent's ~/.ssh effects in the scope's fake home: the managed config and its
//  alias-keyed pins (A1a, W1-2), a second agent that leaves them alone (V9), and an
//  authorized_keys the agent can't write or read (C21). Every VM here has Guest Setup and NO
//  network device, so no discovery or readiness probe runs: the guest's report (written by
//  the Alpine fixture over virtiofs) is the only source, its IP a claim. The real ~/.ssh is
//  never read; ssh -G reads only -F <fake home>/.ssh/machman/config.
//

import CryptoKit
import Foundation
import Testing
import MachmanAPI
import MachmanClient
import MachmanTestSupport
@testable import MachmanDesktopCore

@Suite("Engine — ssh state", .serialized, .enabled(if: Lab.runs(.l2)))
@MainActor
struct EngineSSHStateTests {
	static let claimedIP = "192.168.64.250"

	static func spec(_ name: String) -> LabVMSpec {
		LabVMSpec(name: name, boot: .alpine(), devices: [.guestSetup])
	}

	/// Boots `vm` (if needed), writes `report` from the guest and waits until the agent
	/// serves its user. Returns the console (left open for later reports).
	@discardableResult
	static func seed(_ agent: LabAgent, _ vm: String, _ report: TFReport) async throws
		-> LabConsole {
		if try await agent.api.vm(named: vm).state != .running {
			try await TFVM.start(agent, vm)
		}
		let console = try await LabConsole.connect(
			try await consolePath(agent, vm), transcript: "\(agent.scope.id)-\(vm)-seed")
		try await console.expect("LAB-READY", timeout: .seconds(60))
		try await TFGuest.mountShare(console)
		try await TFGuest.writeReport(console, report.render())
		try await TFWait.vm(agent.api, vm, "reported", timeout: .seconds(20)) {
			$0.ssh?.guestUser == "root"
		}
		return console
	}

	/// seed, then the VM stopped and its vmhost gone: the agent re-reads the config the vmhost
	/// saved, report and all (its own copy is stale while a vmhost owns the VM), and the
	/// managed ~/.ssh entry falls back to the report's address (no discovery without NAT).
	static func seedStopped(_ agent: LabAgent, _ vm: String, _ report: TFReport) async throws {
		let console = try await seed(agent, vm, report)
		console.close()
		await TFVM.forceStop(agent, vm)
		try await TFWait.vm(agent.api, vm, "stopped with its report", timeout: .seconds(20)) {
			$0.state == .stopped && $0.ssh?.guestUser == "root"
		}
	}

	static func consolePath(_ agent: LabAgent, _ vm: String) async throws -> String {
		var path: String?
		try await TFWait.until("\(vm)'s console socket", timeout: .seconds(10)) {
			path = try await agent.api.vm(named: vm).consolePorts?.first?.socketPath
			return path != nil
		}
		return path!
	}

	static func hostKey(_ agent: LabAgent, _ name: String) async throws -> String {
		try await TFReport.keyPair(in: agent.scope.dir + "/keys", name: name).publicLine
	}

	static func managedConfig(_ agent: LabAgent) -> String {
		(try? String(
			contentsOfFile: agent.scope.homeDir + "/.ssh/machman/config", encoding: .utf8)) ?? ""
	}

	static func managedPins(_ agent: LabAgent) -> [String] {
		((try? String(
			contentsOfFile: agent.scope.homeDir + "/.ssh/machman/known_hosts", encoding: .utf8))
			?? "").split(separator: "\n").map(String.init)
	}

	/// The marker labeling a VM's host-side lines: "machman-" and the first 12 hex digits of
	/// the SHA-256 of its vm_identifier (SSHSetupInstaller.existingMarker).
	static func marker(_ agent: LabAgent, _ vm: String) throws -> String {
		let file = TFVM.dir(agent, vm) + "/vm_identifier"
		let data = try Data(contentsOf: URL(fileURLWithPath: file))
		let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
		return "machman-" + hex.prefix(12)
	}

	@Test("A1a: an alias rename regenerates the managed config and moves the known_hosts pin")
	func aliasRenameMovesPin() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(Self.spec("dev"), start: false) { vm in
				let key = try await Self.hostKey(agent, "dev-host")
				try await Self.seedStopped(
					agent, "dev", .standard(ip: Self.claimedIP, hostKey: key))
				try await TFVM.settled {
					_ = try await agent.api.setSSH(
						vm: "dev", integrationEnabled: true, reverseApproved: nil, alias: nil)
				}
				let fields = key.split(separator: " ")
				try await TFWait.until("the managed Host block", timeout: .seconds(10)) {
					Self.managedConfig(agent).contains("Host \"dev.machman\"")
				}
				#expect(Self.managedPins(agent) == ["dev.machman \(fields[0]) \(fields[1])"])
				let desktop = try await TFDesktop.make(agent: agent)
				desktop.viewModel.setSSHAlias("dev", alias: "dev")
				try await TFWait.until("the renamed Host block", timeout: .seconds(10)) {
					let config = Self.managedConfig(agent)
					return config.contains("Host \"dev\"") && !config.contains("dev.machman")
				}
				#expect(Self.managedPins(agent) == ["dev \(fields[0]) \(fields[1])"])
				let resolved = try await Subprocess.run(
					"/usr/bin/ssh",
					["-G", "-F", agent.scope.homeDir + "/.ssh/machman/config", "dev"],
					environment: ["PATH": "/usr/bin:/bin", "HOME": agent.scope.homeDir])
				#expect(resolved.status == 0)
				let lines = Set(resolved.output.split(separator: "\n").map(String.init))
				#expect(lines.contains("hostname \(Self.claimedIP)"))
				#expect(lines.contains("hostkeyalias dev"))
				let pinned = "userknownhostsfile \(agent.scope.homeDir)/"
				#expect(lines.contains { $0.hasPrefix(pinned) })
				await desktop.close()
				_ = vm
			}
		}
	}

	@Test("W1-2: a duplicate beside dev-copy answers to dev-copy-2.machman and keeps it")
	func duplicateBesideDevCopy() async throws {
		try await Lab.withAgent { agent in
			let api = agent.api
			let blank = try await api.createVM(template: .blank)
			try await api.renameVM(named: blank.name, to: "dev-copy")
			try await agent.withVM(Self.spec("dev"), start: false) { _ in
				let copy = try await api.copyVM(
					vm: "dev", newName: "dev copy", diskIDs: nil, mountIDs: nil,
					regenerateMAC: true)
				#expect(copy.name == "dev copy")
				let key = try await Self.hostKey(agent, "copy-host")
				try await Self.seedStopped(
					agent, "dev copy", .standard(ip: Self.claimedIP, hostKey: key))
				let served = try await TFVM.settled {
					try await api.setSSH(
						vm: "dev copy", integrationEnabled: true, reverseApproved: nil,
						alias: nil)
				}
				#expect(served.ssh?.alias == "dev-copy-2.machman")
				try await TFWait.until("the copy's Host block", timeout: .seconds(10)) {
					Self.managedConfig(agent).contains("Host \"dev-copy-2.machman\"")
				}
				try await api.deleteVM(named: "dev-copy")
				try await Task.sleep(for: .seconds(2))
				#expect(try await api.vm(named: "dev copy").ssh?.alias == "dev-copy-2.machman")
				#expect(Self.managedConfig(agent).contains("Host \"dev-copy-2.machman\""))
				try await api.deleteVM(named: "dev copy")
			}
		}
	}

	@Test(
		"""
		R3W2-6: a second agent of the same build exits silently and leaves the VMs and \
		~/.ssh alone
		""")
	func secondAgentStepsAside() async throws {
		try await Lab.withAgent { agent in
			try await agent.withVM(Self.spec("second-agent"), start: false) { vm in
				let key = try await Self.hostKey(agent, "second-agent-host")
				try await Self.seedStopped(
					agent, "second-agent", .standard(ip: Self.claimedIP, hostKey: key))
				try await TFVM.settled {
					_ = try await agent.api.setSSH(
						vm: "second-agent", integrationEnabled: true, reverseApproved: nil,
						alias: nil)
				}
				let config = agent.scope.homeDir + "/.ssh/machman/config"
				try await TFWait.until("the managed config", timeout: .seconds(10)) {
					Self.managedConfig(agent).contains("Host \"second-agent.machman\"")
				}
				// Serving a running VM, its ~/.ssh entry settled.
				try await TFVM.start(agent, "second-agent")
				try await Task.sleep(for: .seconds(3))
				let before = try FileManager.default.attributesOfItem(atPath: config)[
					.modificationDate] as? Date
				let mark = LabLog.mark()
				let second = try await TFAgents.launchSecond(scope: agent.scope)
				defer {
					Task { await TFAgents.stopSecond(pid: second, api: nil, scope: agent.scope) }
				}
				#expect(await LabProcesses.waitForExit(second, timeout: .seconds(15)))
				let lines = TFAgents.logLines(after: mark, pid: second, matching: ".")
				#expect(lines.contains { $0.contains("is already serving") })
				#expect(!lines.contains { $0.contains("test prompt") })
				#expect(try await agent.control("ping") == "ok")
				#expect(try await vm.info().state == .running)
				try await Task.sleep(for: .seconds(2))
				let after = try FileManager.default.attributesOfItem(atPath: config)[
					.modificationDate] as? Date
				#expect(after == before)
			}
		}
	}

	@Test("R3W2-10: approving into an unwritable authorized_keys names the file and stays pending")
	func approveIntoUnwritableKeys() async throws {
		try await Lab.withAgent { agent in
			let home = agent.scope.homeDir
			let ro = home + "/ro"
			try FileManager.default.createDirectory(
				atPath: home + "/.ssh", withIntermediateDirectories: true)
			try FileManager.default.createDirectory(atPath: ro, withIntermediateDirectories: true)
			try "".write(toFile: ro + "/authorized_keys", atomically: true, encoding: .utf8)
			try FileManager.default.createSymbolicLink(
				atPath: home + "/.ssh/authorized_keys",
				withDestinationPath: "../ro/authorized_keys")
			chmod(ro, 0o555)
			defer { chmod(ro, 0o755) }
			try await agent.withVM(Self.spec("unwritable-keys"), start: false) { _ in
				let reverse = try await TFReport.keyPair(
					in: agent.scope.dir + "/keys", name: "unwritable-rev")
				let console = try await Self.seed(
					agent, "unwritable-keys", .standard(reverse: reverse.publicLine))
				defer { console.close() }
				try await TFWait.vm(
					agent.api, "unwritable-keys", "pending", timeout: .seconds(10)
				) {
					$0.ssh?.reverseState == .pending
				}
				let desktop = try await TFDesktop.make(agent: agent)
				desktop.viewModel.setSSHReverseApproved("unwritable-keys", approved: true)
				try await TFWait.until("the approval alert", timeout: .seconds(10)) {
					desktop.viewModel.presentedError != nil
				}
				let alert = try #require(desktop.viewModel.presentedError)
				#expect(alert.title == "Updating guest access failed")
				#expect(alert.message.contains(ro + "/authorized_keys")
					|| alert.message.contains(home + "/.ssh/authorized_keys"))
				#expect(alert.message.contains("can’t be written"))
				#expect(
					try await agent.api.vm(named: "unwritable-keys").ssh?.reverseState == .pending)
				await desktop.close()
			}
		}
	}

	@Test("R3W2-47: an unreadable authorized_keys warns once per VM, and a revoke names the line")
	func unreadableKeysWarnOncePerVM() async throws {
		try await Lab.withAgent { agent in
			let keys = agent.scope.homeDir + "/.ssh/authorized_keys"
			try FileManager.default.createDirectory(
				atPath: agent.scope.homeDir + "/.ssh", withIntermediateDirectories: true)
			try "# lab\n".write(toFile: keys, atomically: true, encoding: .utf8)
			let events = await TFEvents(api: agent.api)
			defer { events.stop() }
			try await agent.withVM(Self.spec("revoked"), start: false) { _ in
				try await agent.withVM(Self.spec("deleted"), start: false) { _ in
					var consoles: [String: LabConsole] = [:]
					var reports: [String: TFReport] = [:]
					defer { consoles.values.forEach { $0.close() } }
					for vm in ["revoked", "deleted"] {
						let reverse = try await TFReport.keyPair(
							in: agent.scope.dir + "/keys", name: "\(vm)-rev")
						reports[vm] = .standard(reverse: reverse.publicLine)
						consoles[vm] = try await Self.seed(agent, vm, reports[vm]!)
					}
					chmod(keys, 0o000)
					defer { chmod(keys, 0o600) }
					let once = "Couldn’t read ~/.ssh/authorized_keys to remove the guest’s key"
					for round in 1...2 {
						for vm in ["revoked", "deleted"] {
							var report = reports[vm]!
							report.pairs.append((key: "NOTE", value: "round \(round)"))
							try await TFGuest.writeReport(consoles[vm]!, report.render())
						}
						try await Task.sleep(for: .seconds(5))
					}
					for vm in ["revoked", "deleted"] {
						let warned = events.logs(vm: vm, level: .warning).filter { $0 == once }
						#expect(warned.count == 1)
					}
					let markerP = try Self.marker(agent, "revoked")
					_ = try await agent.api.setSSH(
						vm: "revoked", integrationEnabled: nil, reverseApproved: false, alias: nil)
					let revoke = "Couldn’t read ~/.ssh/authorized_keys — delete the line ending in "
					try await events.waitFor("revoked's revoke warning", timeout: .seconds(10)) {
						$0 == .log(
							vm: "revoked", level: .warning,
							message: revoke + "machman:\(markerP):revoked")
					}
					let markerQ = try Self.marker(agent, "deleted")
					consoles["deleted"]?.close()
					await TFVM.forceStop(agent, "deleted")
					try await TFVM.settled { try await agent.api.deleteVM(named: "deleted") }
					try await events.waitFor("deleted's delete warning", timeout: .seconds(10)) {
						$0 == .log(
							vm: "deleted", level: .warning,
							message: revoke + "machman:\(markerQ):deleted")
					}
				}
			}
		}
	}
}
