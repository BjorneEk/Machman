//
//  ServerConcurrencyTests.swift
//  MachmanTests
//
//  A5: requests on one connection run concurrently, as docs/ipc-protocol.md (Framing) says —
//  replies come back by id, in whatever order the work finishes. The desktop multiplexes the
//  list, preview polls and every action over ONE connection, so a quick call must not queue
//  behind a slow one; this pins that contract against an accidental per-connection FIFO.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct ServerConcurrencyTests {
	@Test @MainActor func aQuickCallIsAnsweredWhileASlowOneIsInFlight() async throws {
		let socketPath = TestEnvironment.socketPath("mm-conc")
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha")
		stub.stalled = ["vm"]   // vm.get parks until released
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		defer { server.stop() }
		let client = try await RemoteMachman(socketPath: socketPath, clientName: "a5")

		let finished = Finished()
		let slow = Task {
			let info = try await client.vm(named: "alpha")
			finished.slow = true
			return info
		}
		#expect(await eventually { stub.calls.contains("vm") })
		// Same connection, sent after the parked one: answered while it is still parked.
		#expect(try await client.listVMs().map(\.name) == ["alpha"])
		#expect(!finished.slow)

		stub.stalled = []
		#expect(try await slow.value.name == "alpha")
		#expect(finished.slow)
	}
}

@MainActor
private final class Finished {
	var slow = false
}
