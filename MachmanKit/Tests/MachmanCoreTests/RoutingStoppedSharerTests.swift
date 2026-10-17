//
//  RoutingStoppedSharerTests.swift
//  MachmanTests
//
//  E71: a VM whose run is over stays hosted until the router hears its vmhost exit — the death
//  watch or the dropped connection, a moment after the VM lists stopped — and the start guards
//  counted it as running: a start right after a disk sharer's force stop, its vmhost already
//  gone, was refused "<B> is running with <disk> attached". A start now waits such a sharer
//  out. alpha and beta name one scratch image (or one MAC); beta's vmhost is a stub adopted
//  over a scratch socket, its exit its server stopping with isProcessAlive saying it's gone.
//  Every wait runs on a TestClock: a check reads what is armed and advances once.
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

@MainActor
private final class Flag {
	var raised = false
}

struct RoutingStoppedSharerTests {
	private struct Rig {
		let routing: RoutingMachman
		let clock: TestClock
		let server: MachmanServer
		let liveness: Liveness

		// beta's vmhost exits: its process is gone and its connection drops.
		@MainActor
		func exit() {
			liveness.alive = false
			server.stop()
		}
	}

	// alpha and beta share one image (`shareDisk`) and/or one MAC; beta's vmhost is adopted,
	// its VM run and stopped (`runOver`) — what the router knows once a force stop returned —
	// or still running.
	@MainActor
	private func makeRig(
		shareDisk: Bool = true, mac: String? = nil, runOver: Bool = true
	) async throws -> Rig {
		let image = TestEnvironment.scratch + "shared-\(UUID().uuidString).img"
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			for name in ["alpha", "beta"] {
				try VMConfig.createNewVMDirectory(name: name)
				let cfg = try VMConfig(name: name, memorySize: 2048, cpuCount: 2)
				if let mac { cfg.macAddress = mac }
				if shareDisk {
					try cfg.addDisk(disk: VMDisk(kind: .fromUrl(URL(fileURLWithPath: image))))
				}
				try cfg.saveVMConfig()
			}
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }   // a test never finds (or launches) a real vmhost
		}
		let betaSocket = TestEnvironment.socketPath("mm-e71-b")
		routing.socketPathForVM = { $0 == "beta" ? betaSocket : betaSocket + ".none-" + $0 }
		let liveness = Liveness()
		routing.isProcessAlive = { _ in liveness.alive }
		let clock = TestClock()
		routing.clock = clock
		let stub = StubMachman()
		stub.vms["beta"] = StubMachman.makeInfo("beta", state: .running)
		let server = MachmanServer(api: stub, socketPath: betaSocket, daemonVersion: "test")
		try startServing(server)
		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "beta", socketPath: betaSocket, macInUse: mac)
		routing.adopt(identity: identity, client: try await routing.connectHost(identity: identity))
		let host = try #require(routing.hostForTesting("beta"))
		await host.eventsSubscribed?.value
		#expect(await eventually { clock.armed.isEmpty })   // the subscription's call deadline
		host.sawRun = true
		if runOver {
			stub.vms["beta"]?.state = .stopped
		}
		host.lastAnswer = stub.vms["beta"]
		return Rig(routing: routing, clock: clock, server: server, liveness: liveness)
	}

	// The start's answer: its refusal, or the spawn's failure once it got past the guards (no
	// test finds a vmhost to launch).
	@MainActor
	private func startAlpha(_ routing: RoutingMachman) async -> String {
		do {
			try await routing.start(vm: "alpha", options: StartOptions(openWindow: false))
			return "started"
		} catch {
			return MachmanError.userMessage(for: error)
		}
	}

	// A start in a Task, and whether it has answered yet.
	@MainActor
	private func startInTask(_ rig: Rig) -> (Task<String, Never>, Flag) {
		let done = Flag()
		let start = Task { @MainActor in
			defer { done.raised = true }
			return await startAlpha(rig.routing)
		}
		return (start, done)
	}

	@Test("E71: a start waits out a disk sharer's vmhost still exiting after its stop")
	@MainActor func aStartWaitsOutAnExitingSharer() async throws {
		let rig = try await makeRig()
		let (start, done) = startInTask(rig)
		#expect(await eventually { done.raised || rig.clock.armed == [.milliseconds(50)] })
		#expect(!done.raised, "decided before beta's vmhost exited")
		rig.exit()
		#expect(await eventually { rig.routing.hostedNames.isEmpty })
		rig.clock.advance(by: .milliseconds(50))
		let answer = await start.cancellableValue()
		#expect(!answer.contains("is running with"), "\(answer)")
		#expect(answer.contains("reinstall Machman"), "\(answer)")   // past the guards
	}

	// The lab's order: beta's vmhost is gone and its connection dropped, but the hop that tells
	// the router comes to the main actor after the start.
	@Test(
		"""
		E71: a start right after a disk sharer's vmhost exited goes ahead before the agent \
		heard of it
		""")
	@MainActor func aStartAfterTheExitGoesAhead() async throws {
		let rig = try await makeRig()
		rig.exit()
		let (start, done) = startInTask(rig)
		#expect(await eventually { done.raised || !rig.clock.armed.isEmpty })
		#expect(await eventually { rig.routing.hostedNames.isEmpty })
		rig.clock.advance(by: .milliseconds(50))
		let answer = await start.cancellableValue()
		#expect(!answer.contains("is running with"), "\(answer)")
		#expect(answer.contains("reinstall Machman"), "\(answer)")
	}

	@Test("E71: a disk sharer's vmhost that overstays its exit is still shutting down")
	@MainActor func anOverstayingSharerIsStillShuttingDown() async throws {
		let rig = try await makeRig()
		defer { rig.server.stop() }
		let (start, done) = startInTask(rig)
		#expect(await eventually { done.raised || rig.clock.armed == [.milliseconds(50)] })
		rig.clock.advance(by: rig.routing.hostExitGrace)
		let answer = await start.cancellableValue()
		#expect(answer == "beta is still shutting down — try again in a moment")
		#expect(rig.routing.hostedNames == ["beta"])
	}

	@Test("E71: a MAC sharer whose run is over is waited out too")
	@MainActor func aStoppedMACSharerIsWaitedOut() async throws {
		let rig = try await makeRig(shareDisk: false, mac: "aa:bb:cc:71:00:01")
		let (start, done) = startInTask(rig)
		#expect(await eventually { done.raised || rig.clock.armed == [.milliseconds(50)] })
		#expect(!done.raised, "decided before beta's vmhost exited")
		rig.exit()
		#expect(await eventually { rig.routing.hostedNames.isEmpty })
		rig.clock.advance(by: .milliseconds(50))
		let answer = await start.cancellableValue()
		#expect(answer.contains("reinstall Machman"), "\(answer)")   // no macConflict
	}

	@Test("E71: a running disk sharer still refuses at once")
	@MainActor func aRunningSharerRefusesAtOnce() async throws {
		let rig = try await makeRig(runOver: false)
		defer { rig.server.stop() }
		let armed = rig.clock.everArmed
		let answer = await startAlpha(rig.routing)
		#expect(answer.hasPrefix("beta is running with shared-"), "\(answer)")
		#expect(rig.clock.everArmed == armed)
	}

	@Test("E71: a vmhost whose run is over and that shares nothing costs a start no wait")
	@MainActor func aLeavingNonSharerCostsNothing() async throws {
		let rig = try await makeRig(shareDisk: false)
		defer { rig.server.stop() }
		let armed = rig.clock.everArmed
		let answer = await startAlpha(rig.routing)
		#expect(answer.contains("reinstall Machman"), "\(answer)")
		#expect(rig.clock.everArmed == armed)
	}
}
