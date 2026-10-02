//
//  ServerConnectionLifetimeTests.swift
//  MachmanTests
//
//  E13: the server's per-connection bookkeeping. A closed client must be released (no
//  Client -> connection -> onLine -> Client cycle), and the cleanup of a closed connection
//  must never touch a newer client that happens to get the same descriptor number — the
//  kernel hands a closed number out again at once.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct ServerConnectionLifetimeTests {
	@Test @MainActor func aDisconnectedClientIsReleased() async throws {
		let socketPath = TestEnvironment.socketPath("mm-life")
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha")
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		defer { server.stop() }

		let client = try await RemoteMachman(socketPath: socketPath, clientName: "lifetime")
		_ = try await client.listVMs()
		#expect(server.connectionCount == 1)
		weak var accepted = server.clientsForTesting().first
		#expect(accepted != nil)

		await client.disconnect()
		#expect(await eventually { server.connectionCount == 0 && accepted == nil })
	}

	// The stale cleanup of a closed connection runs on the main actor after its descriptor
	// is already closed. Holding the main actor until the close happened, then accepting a
	// new connection on the reused number, puts that cleanup behind the new client.
	@Test @MainActor func aStaleCloseNeverRemovesTheClientThatReusedItsNumber() async throws {
		let server = MachmanServer(
			api: StubMachman(), socketPath: "/nonexistent", daemonVersion: "test")
		for _ in 0..<20 {
			var first: [Int32] = [-1, -1]
			guard socketpair(AF_UNIX, SOCK_STREAM, 0, &first) == 0 else { continue }
			let reused = first[0]
			server.accept(reused)
			close(first[1])   // the peer leaves: the server closes `reused` on its own queue
			// Block the main actor until the server's queue has closed the number: its
			// main-actor cleanup is then queued behind this test.
			let deadline = Date().addingTimeInterval(2)
			while fcntl(reused, F_GETFD) != -1, Date() < deadline { usleep(1000) }
			guard fcntl(reused, F_GETFD) == -1 else { continue }   // a parallel test took it
			var second: [Int32] = [-1, -1]
			guard socketpair(AF_UNIX, SOCK_STREAM, 0, &second) == 0 else { continue }
			guard second[0] == reused else {
				close(second[0])
				close(second[1])
				continue
			}
			server.accept(second[0])
			try await Task.sleep(for: .milliseconds(100))   // the stale cleanup runs now
			#expect(server.connectionCount == 1)
			close(second[1])
			#expect(await eventually { server.connectionCount == 0 })
			return
		}
		// The kernel never handed the number back in 20 tries (parallel tests opened files in
		// between): nothing to assert, the race could not be staged.
		server.stop()
	}
}
