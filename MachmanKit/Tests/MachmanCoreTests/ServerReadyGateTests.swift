//
//  ServerReadyGateTests.swift
//  MachmanTests
//
//  The server's startup-reconciliation gate (E3): the socket is claimed first (it is the
//  daemon mutex), but requests park until adoption finishes — except hello (the version
//  handshake) and daemon.retire (the replace-older takeover), which must answer even if
//  reconciliation wedges. Exercised over a real socket against the stub engine.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct ServerReadyGateTests {
	@MainActor
	private final class Flag {
		var value = false
	}

	@Test @MainActor func requestsParkUntilTheGateOpensButHelloAndRetireAnswer() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-gate-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }
		let (stream, continuation) = AsyncStream<Void>.makeStream()
		server.holdRequests(until: Task { for await _ in stream {} })

		// hello is ungated: the handshake inside RemoteMachman.init completes while the
		// gate is still closed — this connect would hang otherwise.
		let client = try await RemoteMachman(socketPath: socketPath, clientName: "gate")
		#expect(client.hello.daemonVersion == "test")

		// retire is ungated: a wedged-reconciliation daemon can still be replaced.
		try await client.retire()
		#expect(stub.retired)

		// Everything else parks…
		let listDone = Flag()
		let listTask = Task { @MainActor in
			_ = try? await client.listVMs()
			listDone.value = true
		}
		try? await Task.sleep(for: .milliseconds(250))
		#expect(!listDone.value)

		// …and completes once reconciliation finishes.
		continuation.finish()
		await listTask.value
		#expect(listDone.value)
		await client.disconnect()
	}

	@Test @MainActor func aFinishedGateAddsNoHold() async throws {
		let socketPath = TestEnvironment.scratch
			+ "mm-gate2-\(getpid())-\(UInt32.random(in: 0..<99999)).sock"
		let stub = StubMachman()
		stub.vms["Debian"] = StubMachman.makeInfo("Debian")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try server.start()
		defer { server.stop() }
		server.holdRequests(until: Task {})

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "gate2")
		#expect(try await client.listVMs().map(\.name) == ["Debian"])
		await client.disconnect()
	}
}
