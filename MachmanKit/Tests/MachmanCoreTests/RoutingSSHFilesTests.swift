//
//  RoutingSSHFilesTests.swift
//  MachmanTests
//
//  C22 (and E40's ~/.ssh half): regenerating ~/.ssh/machman/config asked each hosted
//  vmhost in turn with the 30 s default deadline, and a VM whose host didn't answer was
//  left out — its alias and pinned key vanished from ~/.ssh while the guest was fine. The
//  hosts are asked at once now, each bounded like a list probe, and a host that misses
//  the deadline keeps its VM's entry from the daemon's copy.
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
	private struct Host {
		let stub: StubMachman
		let server: MachmanServer
	}

	@Test func stalledHostsKeepTheirVMsAndAreAskedAtOnce() async throws {
		let sshDir = TestEnvironment.scratchURL
			.appendingPathComponent("machman-routing-ssh-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: sshDir) }
		let names = ["alpha", "beta", "gamma"]
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for (index, name) in names.enumerated() {
				try VMConfig.createNewVMDirectory(name: name)
				let config = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
				// What the daemon's copy knows: the state before this run.
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
		let deadline = 5
		routing.hostProbeDeadline = .seconds(deadline)
		// One stub vmhost per VM; beta's and gamma's never answer vm.get in time.
		var hosts: [Host] = []
		for name in names {
			let stub = StubMachman()
			var info = StubMachman.makeInfo(name, state: .running)
			info.ssh = SSHInfo(
				configured: true, guestUser: "admin", integrationEnabled: true,
				alias: "\(name)-now.machman")
			stub.vms[name] = info
			if name != "alpha" { stub.stalled = ["vm"] }
			let path = TestEnvironment.socketPath("mm-sf", suffix: "") + ".sock"
			let server = MachmanServer(api: stub, socketPath: path, daemonVersion: "test")
			try startServing(server)
			hosts.append(Host(stub: stub, server: server))
			let identity = RoutingMachman.HostIdentity(id: UUID(), name: name, socketPath: path)
			let client = try await routing.connectHost(identity: identity)
			routing.adopt(identity: identity, client: client)
		}
		defer {
			for host in hosts {
				host.stub.stalled = []
				host.server.stop()
			}
		}

		let clock = ContinuousClock()
		let started = clock.now
		routing.scheduleSSHHostConfigWrite()
		await routing.sshFiles?.settled()
		let elapsed = clock.now - started

		let text = (try? String(
			contentsOf: sshDir.appendingPathComponent("machman/config"), encoding: .utf8)) ?? ""
		#expect(text.contains(#"Host "alpha-now.machman""#))      // its vmhost's answer
		#expect(text.contains(#"Host "beta-before.machman""#))    // kept, from the daemon's copy
		#expect(text.contains(#"Host "gamma-before.machman""#))
		#expect(text.contains("HostName 192.168.64.12"))
		// One deadline for the two stalled hosts together, not one each.
		#expect(elapsed < .seconds(2 * deadline - 1), "took \(elapsed)")
		for name in names {
			await routing.hostForTesting(name)?.client.disconnect()
		}
	}
}
