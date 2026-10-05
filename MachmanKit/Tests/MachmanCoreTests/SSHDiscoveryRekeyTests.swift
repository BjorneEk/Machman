//
//  SSHDiscoveryRekeyTests.swift
//  MachmanTests
//
//  E42: Save as New VM re-keys a running safe run's host, but its SSH discovery kept the
//  name it started with. Every sshChanged it sent afterwards — the address, "ready" or
//  "unreachable" — named the original (stopped by then): clients refetched that one and the
//  saved VM's row stayed "waiting for SSH". And a discovery the vmhost's own running event
//  restarted just before the re-key asked for the original by name, found nothing, and never
//  watched readiness at all.
//

import Testing
import Foundation
import MachmanAPI
import MachmanClient
import MachmanFixtures
import MachmanTestSupport
@testable import MachmanCore

// The address answer waits for the test to open this; sshd always answers.
@MainActor
private final class AddressGate {
	private var isOpen = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	func wait() async {
		guard !isOpen else { return }
		await withCheckedContinuation { waiters.append($0) }
	}

	func open() {
		isOpen = true
		waiters.forEach { $0.resume() }
		waiters = []
	}

	var probes: SSHDiscovery.Probes {
		SSHDiscovery.Probes(
			address: { _ in
				await self.wait()
				return SSHDiscovery.Answer(address: "192.168.64.20", source: "dhcp")
			},
			sshd: { _ in true })
	}
}

// The VM names the router's sshChanged events carried, in order.
@MainActor
private final class Announced {
	var names: [String] = []
}

@MainActor
struct SSHDiscoveryRekeyTests {
	private struct Rig {
		let routing: RoutingMachman
		let stub: StubMachman
		let server: MachmanServer
		let host: RoutingMachman.HostedVM
		let announced: Announced
		let listener: Task<Void, Never>
	}

	private func info(_ name: String) -> VMInfo {
		var info = StubMachman.makeInfo(name, state: .running)
		info.ssh = SSHInfo(configured: true, guestUser: "admin")
		return info
	}

	// A safe run of "alpha" adopted from a stub vmhost, its discovery left to the test.
	private func adoptSafeRun() async throws -> Rig {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			_ = try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2)
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }
		}
		let base = TestEnvironment.socketPath("mm-dk", suffix: "")
		routing.socketPathForVM = { $0 == "kept" ? base + "-k.sock" : base + "-a.sock" }
		let stub = StubMachman()
		var alpha = info("alpha")
		alpha.safeRun = true
		stub.vms["alpha"] = alpha
		let server = MachmanServer(api: stub, socketPath: base + "-a.sock", daemonVersion: "test")
		try startServing(server)
		// No MAC yet, so adoption starts no live discovery; the test starts its own.
		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: base + "-a.sock",
			isSafe: true, shadowRoot: "/nonexistent")
		let client = try await routing.connectHost(identity: identity)
		let host = routing.adopt(identity: identity, client: client)
		host.identity.macInUse = "aa:bb:cc:dd:ee:01"
		let announced = Announced()
		let stream = routing.registry.events.stream()
		let listener = Task { @MainActor in
			for await event in stream {
				if case .sshChanged(let vm) = event { announced.names.append(vm) }
			}
		}
		return Rig(
			routing: routing, stub: stub, server: server, host: host, announced: announced,
			listener: listener)
	}

	// What the daemon does once the vmhost answered the save.
	private func save(_ rig: Rig) throws {
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "kept")
			_ = try VMConfig(name: "kept", memorySize: 2048, cpuCount: 2)
			_ = rig.routing.finishSafeSave(rig.host, from: "alpha", to: "kept", reply: info("kept"))
		}
	}

	private func tearDown(_ rig: Rig) async {
		rig.host.sshDiscoveryTask?.cancel()
		rig.listener.cancel()
		rig.server.stop()
		await rig.host.client.disconnect()
	}

	@Test func afterASaveDiscoveryAnnouncesTheSavedVM() async throws {
		let rig = try await adoptSafeRun()
		let gate = AddressGate()
		rig.routing.startSSHDiscovery(rig.host, probes: gate.probes)
		#expect(await eventually { rig.announced.names == ["alpha"] })   // waiting, as alpha

		rig.stub.vms["alpha"] = nil
		rig.stub.vms["kept"] = info("kept")   // the vmhost serves the saved VM now
		try save(rig)
		gate.open()

		#expect(await eventually { rig.announced.names.count == 3 })
		#expect(rig.announced.names == ["alpha", "kept", "kept"])   // address, then ready
		let kept = try await rig.routing.vm(named: "kept")
		#expect(kept.ssh?.address == "192.168.64.20")
		#expect(kept.ssh?.reachability == .ready)
		await tearDown(rig)
	}

	// The vmhost's running event for the saved VM restarts discovery before the daemon has
	// re-keyed the host: the ask under the original's name finds nothing there any more.
	@Test func aDiscoveryRestartedJustBeforeTheReKeyStillWatchesReadiness() async throws {
		let rig = try await adoptSafeRun()
		rig.host.lastAnswer = rig.stub.vms["alpha"]
		rig.stub.vms["alpha"] = nil
		rig.stub.vms["kept"] = info("kept")
		let gate = AddressGate()
		rig.routing.startSSHDiscovery(rig.host, probes: gate.probes)
		#expect(await eventually { rig.announced.names == ["alpha"] })

		try save(rig)
		gate.open()

		#expect(await eventually { rig.announced.names.count == 3 })
		#expect(rig.announced.names == ["alpha", "kept", "kept"])
		let kept = try await rig.routing.vm(named: "kept")
		#expect(kept.ssh?.reachability == .ready)
		await tearDown(rig)
	}
}
