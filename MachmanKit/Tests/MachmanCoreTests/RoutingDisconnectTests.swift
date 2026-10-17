//
//  RoutingDisconnectTests.swift
//  MachmanTests
//
//  E8: a dropped connection is not a death. Only the vmhost's exit ends a run — before, one
//  spurious read or write failure tore a live safe run down and deleted its shadow. The
//  stub hosts are in-process, so the tests say through isProcessAlive whether one "exited".
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

@MainActor
private final class Liveness {
	var alive = true
}

struct RoutingDisconnectTests {
	@MainActor
	private func makeRouting() throws -> RoutingMachman {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			let cfg = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			try cfg.saveVMConfig()
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }
		}
		routing.hostProbeDeadline = .seconds(10)
		return routing
	}

	@MainActor
	private func safeHost(_ routing: RoutingMachman) async throws
		-> (MachmanServer, String, String) {
		let shadowRoot = TestEnvironment.scratch + "safe-run-\(UUID().uuidString)"
		try FileManager.default.createDirectory(
			atPath: shadowRoot, withIntermediateDirectories: true)
		let socketPath = TestEnvironment.socketPath("mm-drop")
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath,
			isSafe: true, shadowRoot: shadowRoot)
		let client = try await routing.connectHost(identity: identity)
		routing.adopt(identity: identity, client: client)
		return (server, socketPath, shadowRoot)
	}

	// Review F19 (Q40): the reconnect loop kept the router across every pause it slept on the
	// router's clock, so a host dropped on a test's un-advanced clock kept the router alive for
	// good. It sleeps with the router released, as the other loops do.
	@Test("Q40: a reconnect loop asleep on the router's clock doesn't keep the router alive")
	@MainActor func aSleepingReconnectLoopReleasesTheRouter() async throws {
		var routing: RoutingMachman? = try makeRouting()
		let clock = TestClock()
		routing?.clock = clock
		routing?.isProcessAlive = { _ in true }   // the host lives on, its socket dark
		let (server, _, shadowRoot) = try await safeHost(try #require(routing))
		defer {
			server.stop()
			try? FileManager.default.removeItem(atPath: shadowRoot)
		}
		#expect(await eventually { clock.armed.isEmpty })   // the subscription's deadline

		server.stop()   // its connection drops: the loop looks, then pauses within the grace
		#expect(await eventually { clock.armed == [.milliseconds(50)] }, "armed \(clock.armed)")
		weak var released = routing
		routing = nil
		#expect(await eventually { released == nil })
		clock.advance(by: .seconds(60))   // wakes the loop, which finds no router and ends
	}

	@Test @MainActor func aDroppedConnectionToALiveHostReconnects() async throws {
		let routing = try makeRouting()
		routing.isProcessAlive = { _ in true }
		let (server, _, shadowRoot) = try await safeHost(routing)
		defer {
			server.stop()
			try? FileManager.default.removeItem(atPath: shadowRoot)
		}
		let first = try #require(routing.hostForTesting("alpha")?.client)

		await first.disconnect()   // the connection drops; the host lives on
		#expect(await eventually(timeout: .seconds(10)) {
			routing.hostForTesting("alpha").map { $0.client !== first } ?? false
		})
		#expect(routing.hostedNames == ["alpha"])
		#expect(FileManager.default.fileExists(atPath: shadowRoot))   // before: deleted
		let info = try await routing.vm(named: "alpha")
		#expect(info.safeRun == true)
		#expect(info.state == .running)
	}

	@Test @MainActor func aLiveHostWithADarkSocketIsKeptUntilItExits() async throws {
		let routing = try makeRouting()
		let liveness = Liveness()
		routing.isProcessAlive = { _ in liveness.alive }
		routing.hostExitGrace = .milliseconds(200)
		routing.recoveryInterval = .milliseconds(100)
		let (server, _, shadowRoot) = try await safeHost(routing)
		defer { try? FileManager.default.removeItem(atPath: shadowRoot) }

		server.stop()   // socket dark, process (per the seam) alive
		#expect(await eventually(timeout: .seconds(10)) {
			routing.hostForTesting("alpha")?.unresponsive == true
		})
		#expect(routing.hostedNames == ["alpha"])
		#expect(FileManager.default.fileExists(atPath: shadowRoot))   // before: deleted

		liveness.alive = false   // now it exits
		#expect(await eventually(timeout: .seconds(10)) { routing.hostedNames.isEmpty })
		#expect(!FileManager.default.fileExists(atPath: shadowRoot))
	}

	@Test @MainActor func teardownNeverUnlinksALiveSocket() async throws {
		let routing = try makeRouting()
		routing.isProcessAlive = { _ in false }
		let (server, socketPath, shadowRoot) = try await safeHost(routing)
		defer { try? FileManager.default.removeItem(atPath: shadowRoot) }

		server.stop()
		// A new run binds the same path before the old run's teardown runs.
		let successor = MachmanServer(
			api: StubMachman(), socketPath: socketPath, daemonVersion: "test")
		try startServing(successor)
		defer { successor.stop() }
		#expect(await eventually(timeout: .seconds(10)) { routing.hostedNames.isEmpty })
		#expect(UDSListener.isLive(path: socketPath))   // before: unlinked under the successor
	}
}
