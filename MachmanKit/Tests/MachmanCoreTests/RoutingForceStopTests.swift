//
//  RoutingForceStopTests.swift
//  MachmanTests
//
//  E36: Force Stop on a VM whose vmhost stopped answering was forwarded to that host and
//  failed after 30 s, and the quit path's "Force Stop All" left it running without a word.
//  The forwarded force stop is bounded now; a host that misses it is listed as not
//  responding and the stop answers `timeout`, the clients' cue to offer ending its process
//  (C9: only after a second, explicit confirmation). A stub vmhost "wedges" by parking stop.
//  Q40: the checks that bounded wall time run on a TestClock — which deadline is armed, and
//  that one advance past it ends the call.
//

import Testing
import Foundation
import MachmanFixtures
import MachmanTestSupport
import MachmanAPI
import MachmanClient
@testable import MachmanCore

@MainActor
private final class Heard {
	var events: [VMEvent] = []
	var ended: [String] = []
}

// Waits until what is armed on `clock` is exactly `expected` (the deadlines under test, armed
// together), then moves time past them — past anything else armed too, so a wrong deadline
// fails the check instead of hanging the test.
@MainActor
private func passArmed(_ clock: TestClock, _ expected: [Duration]) async {
	#expect(await eventually { clock.armed == expected }, "armed \(clock.armed)")
	clock.advance(by: (clock.armed + expected).max() ?? .zero)
}

// A check that waits on a deadline nothing moves past would hang: the limit ends it.
@Suite(.timeLimit(.minutes(1)))
struct RoutingForceStopTests {
	private struct Rig {
		let routing: RoutingMachman
		let stub: StubMachman
		let server: MachmanServer
	}

	// alpha, running in an adopted stub host. The force stop's bound is short: these tests
	// want it to run out, and it can only expire.
	@MainActor
	private func makeRig(clock: TestClock? = nil) async throws -> Rig {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2).saveVMConfig()
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
			routing.locateVMHost = { nil }   // a test never finds (or launches) a real vmhost
		}
		routing.hostProbeDeadline = .seconds(10)
		routing.forceStopDeadline = .seconds(1)
		if let clock { routing.clock = clock }
		let socketPath = TestEnvironment.socketPath("mm-force")
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		let identity = RoutingMachman.HostIdentity(
			id: UUID(), name: "alpha", socketPath: socketPath)
		routing.adopt(identity: identity, client: try await routing.connectHost(identity: identity))
		// The adoption's event subscription is a call with a deadline: it ends with its reply.
		if let clock { #expect(await eventually { clock.armed.isEmpty }) }
		return Rig(routing: routing, stub: stub, server: server)
	}

	@MainActor
	private func finish(_ rig: Rig) {
		rig.stub.stalled = []
		rig.server.stop()
	}

	@Test("E36: a force stop the vmhost misses answers timeout after the force stop's deadline")
	@MainActor func aForceStopTheHostMissesAnswersTimeout() async throws {
		let clock = TestClock()
		let rig = try await makeRig(clock: clock)
		defer { finish(rig) }
		rig.stub.stalled = ["stop"]
		rig.routing.endHost = { _ in
			Issue.record("a plain force stop ended a process")
			return false
		}

		let stop = Task { @MainActor in try await rig.routing.stop(vm: "alpha", mode: .force) }
		await passArmed(clock, [rig.routing.forceStopDeadline])   // before: the call's 30 s
		do {
			try await stop.value
			Issue.record("a wedged host's force stop went through")
		} catch let error as MachmanError {
			#expect(error.code == .timeout)
			#expect(error.message == "alpha isn\u{2019}t answering, so it didn\u{2019}t stop")
		}
		#expect(rig.routing.hostForTesting("alpha")?.unresponsive == true)
		#expect(rig.routing.hostedNames == ["alpha"])   // listed, never ended here
	}

	// Shut Down asks the guest through the host: one that doesn't answer is refused at once.
	@Test @MainActor func aShutDownOfANotRespondingVMIsRefusedAtOnce() async throws {
		let rig = try await makeRig()
		defer { finish(rig) }
		rig.stub.stalled = ["stop"]
		_ = try? await rig.routing.stop(vm: "alpha", mode: .force)   // marks it
		let asked = rig.stub.calls.filter { $0 == "stop" }.count

		do {
			try await rig.routing.stop(vm: "alpha", mode: .soft)
			Issue.record("a shut down went to a host that doesn't answer")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message == "alpha is not responding \u{2014} use Force Stop")
		}
		#expect(rig.stub.calls.filter { $0 == "stop" }.count == asked)
	}

	// C9: ending the process is its own call, sent after the user's second confirmation.
	@Test @MainActor func endProcessEndsAHostThatDoesntAnswer() async throws {
		let rig = try await makeRig()
		defer { finish(rig) }
		let heard = Heard()
		rig.routing.isProcessAlive = { _ in false }   // the stub host's exit: its server stops
		rig.routing.endHost = { host in
			heard.ended.append(host.identity.name)
			rig.server.stop()
			return true
		}
		let stream = await rig.routing.events()
		let pump = Task { @MainActor in
			for await event in stream { heard.events.append(event) }
		}
		defer { pump.cancel() }
		rig.stub.stalled = ["stop"]
		_ = try? await rig.routing.stop(vm: "alpha", mode: .force)   // listed as not responding

		try await rig.routing.endProcess(vm: "alpha")
		#expect(heard.ended == ["alpha"])
		#expect(rig.routing.hostedNames.isEmpty)   // its exit was cleaned up before the reply
		#expect(await eventually {
			heard.events.contains(.log(
				vm: "alpha", level: .warning,
				message: "Its process wasn\u{2019}t answering, so Machman ended it."))
		})
	}

	@Test @MainActor func endProcessRefusesAHostThatAnswers() async throws {
		let rig = try await makeRig()
		defer { finish(rig) }
		rig.routing.endHost = { _ in
			Issue.record("ended a host that answers")
			return true
		}
		do {
			try await rig.routing.endProcess(vm: "alpha")
			Issue.record("expected a refusal")
		} catch let error as MachmanError {
			#expect(error.code == .invalidState)
			#expect(error.message == "alpha is answering again \u{2014} use Force Stop")
		}
	}

	@Test @MainActor func endProcessWithoutAProcessToEndRefuses() async throws {
		let rig = try await makeRig()
		defer { finish(rig) }
		rig.routing.endHost = { _ in false }
		rig.stub.stalled = ["stop"]
		_ = try? await rig.routing.stop(vm: "alpha", mode: .force)
		do {
			try await rig.routing.endProcess(vm: "alpha")
			Issue.record("expected a refusal")
		} catch let error as MachmanError {
			#expect(error.message
				== "alpha is not responding, and Machman can\u{2019}t end its process")
		}
		#expect(rig.routing.hostedNames == ["alpha"])
	}

	// A vmhost that answers on the socket but could never be adopted ("Not responding"):
	// whoever holds the socket is ended, once it proves a vmhost.
	@Test @MainActor func endProcessEndsAnUnadoptableSocketsHolder() async throws {
		var routing: RoutingMachman!
		try VMTestDir.withRedirectedDir {
			try VMConfig.createNewVMDirectory(name: "alpha")
			try VMConfig(name: "alpha", memorySize: 2048, cpuCount: 2).saveVMConfig()
			routing = RoutingMachman(registry: VMRegistry(), daemonVersion: "test")
		}
		let socketPath = TestEnvironment.socketPath("mm-holder")
		routing.socketPathForVM = { _ in socketPath }
		let listener = try UDSListener(
			path: socketPath, queue: DispatchQueue(label: "mm-holder-accept")) { fd in
				close(fd)
			}
		defer { listener.shutdown() }
		var ended: [String] = []
		routing.endSocketHolder = { path in
			ended.append(path)
			listener.shutdown()
			return true
		}

		try await routing.endProcess(vm: "alpha")
		#expect(ended == [socketPath])
		#expect(routing.hostedNames.isEmpty)
		#expect(!routing.unadoptable.contains("alpha"))
	}

	// The wire: a client reaches the daemon's vm.process.end; the engine half refuses.
	@Test @MainActor func vmProcessEndCrossesTheWire() async throws {
		let socketPath = TestEnvironment.socketPath("mm-pend")
		let stub = StubMachman()
		stub.vms["alpha"] = StubMachman.makeInfo("alpha", state: .running)
		let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
		try startServing(server)
		defer { server.stop() }
		let client = try await RemoteMachman(socketPath: socketPath, clientName: "test")
		try await client.endProcess(vm: "alpha")
		#expect(stub.calls.contains("endProcess"))
		#expect(stub.vms["alpha"]?.state == .stopped)
		await client.disconnect()

		var local: LocalMachman!
		try VMTestDir.withRedirectedDir {
			local = LocalMachman(registry: VMRegistry())
		}
		await #expect(throws: MachmanError.self) { try await local.endProcess(vm: "alpha") }
	}

	// The pid a SIGKILL goes to must still be a vmhost's: never this test process.
	@Test func onlyAVMHostProcessIsEverKilled() {
		#expect(!VMHostProcess.isVMHost(getpid()))
		#expect(!RoutingMachman.killVMHost(pid: getpid()))
	}

	// "Force Stop All & Quit" says which VMs it couldn't stop, and doesn't wait on them.
	@Test("E36: Force Stop All names the hosts it left running and doesn't wait on them")
	@MainActor func stopAllNamesTheHostsLeftRunning() async throws {
		let clock = TestClock()
		let rig = try await makeRig(clock: clock)
		defer { finish(rig) }
		rig.stub.stalled = ["stop"]

		let quit = Task { @MainActor in
			await rig.routing.stopAllHosted(softFirst: false, graceSeconds: 0)
		}
		await passArmed(clock, [rig.routing.forceStopDeadline])
		#expect(await quit.value == ["alpha"])
		#expect(!clock.everArmed.contains(.milliseconds(250)))   // no drain wait on top
	}

	// E66 (K12): Shut Down All asked the vmhosts one at a time, each wedged one adding its
	// deadline, then waited the whole grace while one remained, and force stopped them one at
	// a time again. Every host is asked at once now; one that misses its shut down's deadline
	// is listed as not responding and skips the force pass; the grace ends once only such
	// hosts remain; and Shut Down All & Quit ends them like a confirmed End Process.
	@Test(
		"""
		E66: Shut Down All asks every vmhost at once and ends the ones still not answering \
		after the grace
		""")
	@MainActor func shutDownAllAsksAtOnceAndEndsTheUnanswering() async throws {
		let names = ["alpha", "beta"]
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
		routing.forceStopDeadline = .seconds(6)
		let clock = TestClock()
		routing.clock = clock
		var stubs: [String: StubMachman] = [:]
		var servers: [String: MachmanServer] = [:]
		for name in names {
			let stub = StubMachman()
			stub.vms[name] = StubMachman.makeInfo(name, state: .running)
			stub.stalled = ["stop", "vm"]
			let socketPath = TestEnvironment.socketPath("mm-quit-\(name)")
			let server = MachmanServer(api: stub, socketPath: socketPath, daemonVersion: "test")
			try startServing(server)
			let identity = RoutingMachman.HostIdentity(
				id: UUID(), name: name, socketPath: socketPath)
			routing.adopt(
				identity: identity, client: try await routing.connectHost(identity: identity))
			stubs[name] = stub
			servers[name] = server
		}
		#expect(await eventually { clock.armed.isEmpty })   // the subscriptions' deadlines
		defer {
			for stub in stubs.values { stub.stalled = [] }
			for server in servers.values { server.stop() }
		}
		let heard = Heard()
		routing.isProcessAlive = { _ in false }   // a stub host's exit: its server stops
		routing.endHost = { host in
			heard.ended.append(host.identity.name)
			servers[host.identity.name]?.stop()
			return true
		}

		let quit = Task { @MainActor in
			await routing.stopAllHosted(
				softFirst: true, graceSeconds: 30, endingUnanswered: true)
		}
		// Both asked while each still parks its answer: both shut downs' deadlines are armed
		// before either fires (one at a time, the second is asked after the first's 6 s).
		await passArmed(clock, [.seconds(6), .seconds(6)])
		// Ended like a confirmed End Process; the waits for each to go see it gone.
		#expect(await eventually { routing.hostedNames.isEmpty })
		clock.advance(by: .milliseconds(50))
		let left = await quit.value
		#expect(left.isEmpty)
		#expect(Set(heard.ended) == Set(names))
		// One deadline, not the whole grace (before: 6 + 6 + 30 + 6 + 6 s): no 250 ms grace or
		// drain look ever waited.
		#expect(!clock.everArmed.contains(.milliseconds(250)))
		// The force pass skipped the hosts that missed their shut down: one stop each.
		#expect(stubs.values.allSatisfy { $0.calls.filter { $0 == "stop" }.count == 1 })
		#expect(routing.hostedNames.isEmpty)
	}
}
