//
//  RoutingSSHFilesTests.swift
//  MachmanTests
//
//  C22 (and E40's ~/.ssh half): regenerating ~/.ssh/machman/config asked each hosted
//  vmhost in turn with the 30 s default deadline, and a VM whose host didn't answer was
//  left out — its alias and pinned key vanished from ~/.ssh while the guest was fine. The
//  hosts are asked at once now, each bounded like a list probe, and a host that misses
//  the deadline keeps its VM's entry from the daemon's copy. Q40: the stall check runs on a
//  TestClock — under load the answering host itself missed a 1 s wall-clock deadline.
//

import Testing
import Foundation
import MachmanAPI
import MachmanClient
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

@MainActor
struct RoutingSSHFilesTests {
	private struct Rig {
		let routing: RoutingMachman
		let sshDir: URL
		let stubs: [String: StubMachman]
		let servers: [MachmanServer]

		var managed: String {
			(try? String(
				contentsOf: sshDir.appendingPathComponent("machman/config"), encoding: .utf8))
				?? ""
		}
	}

	// One VM per name, each run by its own stub vmhost; `stalled` ones never answer vm.get.
	// The daemon's copy of each VM knows the alias "<name>-before.machman", its vmhost
	// answers "<name>-now.machman".
	private func makeRig(
		_ names: [String], stalled: Set<String>, deadline: Duration, clock: TestClock? = nil
	) async throws -> Rig {
		let sshDir = TestEnvironment.scratchURL
			.appendingPathComponent("machman-routing-ssh-\(UUID().uuidString)")
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for (index, name) in names.enumerated() {
				try VMConfig.createNewVMDirectory(name: name)
				let config = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
				var ssh = SSHConfig()
				ssh.integrationEnabled = true
				ssh.guestUser = "admin"
				ssh.alias = "\(name)-before.machman"
				ssh.lastAddress = "192.168.64.\(10 + index)"
				config.ssh = ssh
				try config.saveVMConfig()
			}
			routing = RoutingMachman(
				registry: VMRegistry(), daemonVersion: "test",
				sshHostConfig: SSHHostConfigWriter(sshDir: sshDir))
			routing.locateVMHost = { nil }
		}
		routing.hostProbeDeadline = deadline
		if let clock { routing.clock = clock }
		var stubs: [String: StubMachman] = [:]
		var servers: [MachmanServer] = []
		for name in names {
			let stub = StubMachman()
			var info = StubMachman.makeInfo(name, state: .running)
			info.ssh = SSHInfo(
				configured: true, guestUser: "admin", integrationEnabled: true,
				alias: "\(name)-now.machman")
			stub.vms[name] = info
			if stalled.contains(name) { stub.stalled = ["vm"] }
			let path = TestEnvironment.socketPath("mm-sf", suffix: "") + ".sock"
			let server = MachmanServer(api: stub, socketPath: path, daemonVersion: "test")
			try startServing(server)
			stubs[name] = stub
			servers.append(server)
			let identity = RoutingMachman.HostIdentity(id: UUID(), name: name, socketPath: path)
			let client = try await routing.connectHost(identity: identity)
			routing.adopt(identity: identity, client: client)
		}
		// Each adoption's event subscription is a call with a deadline: it ends with its reply.
		if let clock { #expect(await eventually { clock.armed.isEmpty }) }
		return Rig(routing: routing, sshDir: sshDir, stubs: stubs, servers: servers)
	}

	private func finish(_ rig: Rig) async {
		for stub in rig.stubs.values { stub.stalled = [] }
		for server in rig.servers { server.stop() }
		for name in rig.stubs.keys {
			await rig.routing.hostForTesting(name)?.client.disconnect()
		}
		try? FileManager.default.removeItem(at: rig.sshDir)
	}

	@Test("C22: a stalled vmhost keeps its VM's ~/.ssh entry once its probe deadline passes")
	func aStalledHostKeepsItsVM() async throws {
		let clock = TestClock()
		let rig = try await makeRig(
			["alpha", "beta"], stalled: ["beta"], deadline: .seconds(1), clock: clock)

		let armedBefore = clock.everArmed.count
		rig.routing.scheduleSSHHostConfigWrite()
		let written = Task { @MainActor in await rig.routing.sshFiles?.settled() }
		// Both asked at once: alpha's deadline ends with its answer, beta's is what is left.
		#expect(await eventually {
			clock.everArmed.count >= armedBefore + 2 && clock.armed == [.seconds(1)]
		}, "armed \(clock.armed)")
		clock.advance(by: (clock.armed + [.seconds(1)]).max() ?? .zero)
		await written.cancellableValue()

		#expect(rig.managed.contains(#"Host "alpha-now.machman""#))     // its vmhost's answer
		#expect(rig.managed.contains(#"Host "beta-before.machman""#))   // kept, from the copy
		#expect(rig.managed.contains("HostName 192.168.64.11"))
		await finish(rig)
	}

	// C30: `ssh <alias>` run right after vm.ssh.set turned the integration on found no managed
	// config — the write ran after the reply (A1b met it). The reply now waits for it.
	@Test("C30: vm.ssh.set replies once ~/.ssh/machman/config lists the VM's alias")
	func setSSHRepliesAfterTheWrite() async throws {
		// On a TestClock nothing advances: the answer can't miss its deadline however slow.
		let rig = try await makeRig(
			["alpha"], stalled: [], deadline: .seconds(5), clock: TestClock())
		_ = try await rig.routing.setSSH(
			vm: "alpha", integrationEnabled: true, reverseApproved: nil, alias: nil)
		#expect(rig.managed.contains(#"Host "alpha-now.machman""#))
		await finish(rig)
	}

	// Both stalled hosts are asked before either ask could have run out: asked in turn, the
	// second would wait out the first's deadline — on a TestClock nothing advances, so the
	// second would never be asked. Released, both answer fresh.
	@Test("C22: the vmhosts are asked for ~/.ssh at once")
	func theHostsAreAskedAtOnce() async throws {
		let rig = try await makeRig(
			["alpha", "beta", "gamma"], stalled: ["beta", "gamma"], deadline: .seconds(30),
			clock: TestClock())
		let beta = try #require(rig.stubs["beta"])
		let gamma = try #require(rig.stubs["gamma"])

		rig.routing.scheduleSSHHostConfigWrite()
		#expect(await eventually { beta.calls.contains("vm") && gamma.calls.contains("vm") })
		beta.stalled = []
		gamma.stalled = []
		await rig.routing.sshFiles?.settled()

		for name in ["alpha", "beta", "gamma"] {
			#expect(rig.managed.contains("Host \"\(name)-now.machman\""))
		}
		await finish(rig)
	}
}
