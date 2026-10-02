//
//  RoutingStartEventsTests.swift
//  MachmanCoreTests
//
//  E9: what a vmhost logs while its VM boots — the "started without its uart ports" and
//  "started headless" warnings — reaches the daemon's subscribers. The daemon used to
//  subscribe to a host's events only after the forwarded start returned, so a boot's events
//  went to a bus nobody listened on. O-6a: a freshly spawned host, not hosted until its start
//  returns, passes on only its log lines then; its own running state and list changes would
//  race the router's, which lists the VM as starting and announces the run itself (RR3-1:
//  with a stateChanged, then a listChanged).
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

struct RoutingStartEventsTests {
	private static let bootWarning = VMEvent.log(
		vm: "alpha", level: .warning, message: "alpha started without its uart ports")

	@MainActor
	private func makeRouting() throws -> (RoutingMachman, String) {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			let cfg = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			try cfg.saveVMConfig()
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }
		}
		let socketPath = TestEnvironment.socketPath("mm-boot")
		routing.socketPathForVM = { _ in socketPath }
		routing.helloDeadline = .seconds(10)
		routing.hostProbeDeadline = .seconds(10)
		return (routing, socketPath)
	}

	// A stopped VM's stub host that logs a boot warning inside its start, served on `path`.
	@MainActor
	private func bootingHost(_ path: String, extra: [VMEvent] = []) throws
		-> (StubMachman, MachmanServer) {
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha")   // stopped: the start is forwarded
		stub.bootEvents = [Self.bootWarning] + extra
		let server = MachmanServer(api: stub, socketPath: path, daemonVersion: "test")
		try startServing(server)
		return (stub, server)
	}

	@MainActor
	private func collect(_ routing: RoutingMachman) async -> (EventLog, Task<Void, Never>) {
		let collected = EventLog()
		let stream = await routing.events()
		let reader = Task { @MainActor in
			for await event in stream { collected.append(event) }
		}
		return (collected, reader)
	}

	@Test @MainActor func eventsAVMHostEmitsWhileBootingReachTheDaemonsSubscribers() async throws {
		let (routing, socketPath) = try makeRouting()
		let (_, server) = try bootingHost(socketPath)
		defer { server.stop() }
		let (collected, reader) = await collect(routing)
		defer { reader.cancel() }

		#expect(try await routing.probeAdoptAndStart(
			name: "alpha", socketPath: socketPath, options: StartOptions(openWindow: false)))
		#expect(await eventually(timeout: .seconds(15)) {
			collected.events.contains(Self.bootWarning)
		})
	}

	// The spawn path's shape: a host the router connected to but has not hosted yet gets the
	// start (spawnHost itself would launch a real vmhost).
	@Test @MainActor func aHostNotYetHostedPassesOnOnlyItsBootLog() async throws {
		let (routing, socketPath) = try makeRouting()
		let (stub, server) = try bootingHost(socketPath, extra: [.listChanged])
		defer { server.stop() }
		let (collected, reader) = await collect(routing)
		defer { reader.cancel() }

		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath)
		let host = RoutingMachman.HostedVM(
			identity: identity, client: try await routing.connectHost(identity: identity),
			app: nil, deathWatch: nil)
		defer { host.eventTask?.cancel() }
		try await routing.forwardStart(host, name: "alpha", options: StartOptions())
		#expect(stub.starts.count == 1)

		// One connection keeps its order: once this arrives, everything the start emitted has.
		let sentinel = VMEvent.log(vm: "alpha", level: .message, message: "after the start")
		stub.emit(sentinel)
		#expect(await eventually(timeout: .seconds(15)) { collected.events.contains(sentinel) })
		#expect(collected.events.contains(Self.bootWarning))
		#expect(!collected.events.contains(.stateChanged(vm: "alpha", state: .running)))
		#expect(!collected.events.contains(.listChanged))
	}

	// RR3-1: once the start returned, the router hosts the host and announces the run itself,
	// once: the desktop starts a shown VM's preview polling only on a running stateChanged.
	@Test @MainActor func hostingAStartedHostAnnouncesItsRunOnce() async throws {
		let (routing, socketPath) = try makeRouting()
		let (stub, server) = try bootingHost(socketPath)
		defer { server.stop() }
		let (collected, reader) = await collect(routing)
		defer { reader.cancel() }

		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath)
		let host = RoutingMachman.HostedVM(
			identity: identity, client: try await routing.connectHost(identity: identity),
			app: nil, deathWatch: nil)
		defer { host.eventTask?.cancel() }
		try await routing.forwardStart(host, name: "alpha", options: StartOptions())
		// A server sends events from their own task, so the host's running state may trail
		// the start's reply; drain it first, so it is surely the not-yet-hosted host's.
		let started = VMEvent.log(vm: "alpha", level: .message, message: "after the start")
		stub.emit(started)
		#expect(await eventually(timeout: .seconds(15)) { collected.events.contains(started) })
		routing.hostStarted(host, name: "alpha", unattached: [])
		#expect(routing.hostedNames == ["alpha"])

		let hosted = VMEvent.log(vm: "alpha", level: .message, message: "after hosting")
		stub.emit(hosted)
		#expect(await eventually(timeout: .seconds(15)) { collected.events.contains(hosted) })
		let running = VMEvent.stateChanged(vm: "alpha", state: .running)
		// The host's own stayed back; this one is the router's.
		#expect(collected.events.filter { $0 == running }.count == 1)
		let drained = try #require(collected.events.firstIndex(of: started))
		let announced = try #require(collected.events.firstIndex(of: running))
		let reload = try #require(collected.events.firstIndex(of: .listChanged))
		#expect(drained < announced && announced < reload)
	}
}

@MainActor
private final class EventLog {
	private(set) var events: [VMEvent] = []
	func append(_ event: VMEvent) { events.append(event) }
}
