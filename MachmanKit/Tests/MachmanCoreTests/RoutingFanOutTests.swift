//
//  RoutingFanOutTests.swift
//  MachmanCoreTests
//
//  PR23: the router's passes over every vmhost — the quit path's stop-all, the ~/.ssh entry
//  pass — ask through one fan-out: every host at once, each call bounded on its own, and a
//  host listed as not responding left out. Three in-process stub hosts adopted over real
//  sockets; a host "stalls" by parking the scripted calls (StubMachman.stalled).
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct RoutingFanOutTests {
	@Test("E66: the fan-out asks every host at once and leaves out the ones not responding")
	@MainActor func theFanOutAsksEveryHostAtOnce() async throws {
		let names = ["alpha", "beta", "gamma"]
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in names {
				try VMConfig.createNewVMDirectory(name: name)
				try VMConfig(name: name, memorySize: 2048, cpuCount: 2).saveVMConfig()
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }   // a test never finds (or launches) a real vmhost
		}
		routing.hostProbeDeadline = .seconds(10)
		var stubs: [String: StubMachman] = [:]
		var servers: [MachmanServer] = []
		for name in names {
			let stub = StubMachman()
			stub.vms[name] = StubMachman.makeInfo(name, state: .running)
			stub.stalled = ["operations"]
			let socketPath = TestEnvironment.socketPath("mm-fan-\(name)")
			let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
			try startServing(server)
			let identity = RoutingMachman.HostIdentity(
				id: UUID(), name: name, socketPath: socketPath)
			routing.adopt(
				identity: identity, client: try await routing.connectHost(identity: identity))
			stubs[name] = stub
			servers.append(server)
		}
		defer {
			for stub in stubs.values { stub.stalled = [] }
			for server in servers { server.stop() }
		}
		let gamma = try #require(routing.hostForTesting("gamma"))
		gamma.unresponsive = true

		let pass = Task { @MainActor in
			await routing.fanOut(
				to: Dictionary(uniqueKeysWithValues: names.map {
					($0, routing.hostForTesting($0)!)
				}),
				skippingUnresponsive: true
			) { name, host in
				_ = try? await host.client.operations(deadline: .seconds(30))
				return name
			}
		}
		// Both answering hosts are asked while each still parks its answer: one at a time,
		// the second would wait for the first's 30 s.
		#expect(await eventually {
			stubs["alpha"]!.calls.contains("operations")
				&& stubs["beta"]!.calls.contains("operations")
		})
		#expect(!stubs["gamma"]!.calls.contains("operations"))
		for stub in stubs.values { stub.stalled = [] }
		let answers = await pass.value
		#expect(answers == ["alpha": "alpha", "beta": "beta"])
	}
}
