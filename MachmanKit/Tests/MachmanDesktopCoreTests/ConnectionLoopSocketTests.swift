//
//  ConnectionLoopSocketTests.swift
//  MachmanDesktopCoreTests
//
//  The desktop's connect loop as DaemonConnection builds it — ConnectionLoop over the real
//  RemoteMachman — against the fake agent's socket, for what ConnectionLoopTests' fakes
//  can't show: a real hello timeout classified as not answering (P1, W2-27a), a missing
//  socket as "It isn't running." and one launch, an api mismatch stopping at once, a
//  too-old agent's version reaching the status (E32, W4-21a; the replace prompt itself is
//  in the app target), and a start cut off by a real EOF carried to the next attach (P12,
//  W2-28a). The b halves of those rows (a real agent, SIGSTOP, the alert) are the lab's.
//  The launch is a test closure (never NSWorkspace); every session uses the fake's path.
//

import Foundation
import Testing
import MachmanAPI
import MachmanClient
import MachmanTestSupport
@testable import MachmanDesktopCore

// L1: the connect loop over a scripted fake agent socket (no real agent).
@MainActor
struct ConnectionLoopSocketTests {
	@Test("P1: a live agent connects, subscribes to events and reports its version")
	func liveAgentConnects() async throws {
		let rig = try SocketLoopRig()
		defer { rig.close() }
		rig.daemon.otherwise = .agent()
		rig.loop.start()
		#expect(await eventually { rig.loop.status == .connected(daemonVersion: "1.0.12") })
		#expect(rig.daemon.requests.map(\.method)
			== [RPCMethod.hello.rawValue, RPCMethod.eventsSubscribe.rawValue])
		#expect(rig.recorder.sessions.count == 1)
		#expect(rig.recorder.carried == [[]])
		#expect(rig.launches == 0)
	}

	@Test(
		"W2-27a: a silent agent reads not answering after two hello timeouts, and Retry connects")
	func silentAgentReadsNotAnswering() async throws {
		let rig = try SocketLoopRig(helloDeadline: .seconds(2))
		defer { rig.close() }
		rig.daemon.otherwise = .silent
		rig.loop.start()
		#expect(await eventually(timeout: .seconds(30)) { rig.loop.status.problemKind != nil })
		guard case .unavailable(let problem) = rig.loop.status else {
			Issue.record("still \(rig.loop.status)")
			return
		}
		#expect(problem.kind == .notAnswering)
		#expect(problem.title == "Machman Agent is not answering")
		#expect(problem.hint
			== "Choose Quit Machman Agent from its menu-bar item, then click Retry.")
		#expect(problem.detail == "It accepted the connection but didn\u{2019}t answer.")
		#expect(rig.daemon.connectionCount == 2)
		#expect(rig.launches == 0)

		rig.daemon.otherwise = .agent()
		rig.helloDeadline = .seconds(10)
		rig.loop.retry()
		#expect(await eventually { rig.loop.status == .connected(daemonVersion: "1.0.12") })
		#expect(rig.launches == 0)
	}

	@Test("P1: an agent that isn't running is launched once, then connects")
	func missingAgentIsLaunchedOnce() async throws {
		let rig = try SocketLoopRig(listening: false, listenOnLaunch: true)
		defer { rig.close() }
		rig.daemon.otherwise = .agent()
		rig.loop.start()
		#expect(await eventually { rig.loop.status == .connected(daemonVersion: "1.0.12") })
		#expect(rig.launches == 1)
		#expect(rig.daemon.connectionCount == 1)
	}

	@Test("P1: an agent speaking another api version stops at once")
	func otherAPIVersionStopsAtOnce() async throws {
		let rig = try SocketLoopRig()
		defer { rig.close() }
		rig.daemon.otherwise = .agent(apiVersion: MachmanProtocol.apiVersion + 1)
		rig.loop.start()
		#expect(await eventually { rig.loop.status.problemKind != nil })
		#expect(rig.loop.status.problemKind == .incompatible)
		#expect(rig.daemon.connectionCount == 1)
		#expect(rig.launches == 0)
		#expect(rig.recorder.sessions.isEmpty)
	}

	@Test("W4-21a: a too-old agent's version reaches the connected status below the floor")
	func tooOldAgentVersionReachesTheStatus() async throws {
		let floor = try #require(try RepoFiles.daemonFloor(), "oldestCompatibleDaemonVersion moved")
		var parts = floor.split(separator: ".").compactMap { Int($0) }
		let last = try #require(parts.last)
		try #require(last > 0, "the floor \(floor) has no older patch to fake")
		parts[parts.count - 1] = last - 1
		let older = parts.map(String.init).joined(separator: ".")

		let rig = try SocketLoopRig()
		defer { rig.close() }
		rig.daemon.otherwise = .agent(version: older)
		rig.loop.start()
		#expect(await eventually { rig.loop.status == .connected(daemonVersion: older) })
		#expect(MachmanVersion.isOlder(older, than: floor))
		#expect(rig.recorder.sessions.first?.daemonVersion == older)
	}

	@Test("W2-28a: a start cut off by a dropped connection is carried to the next attach")
	func cutOffStartIsCarried() async throws {
		let rig = try SocketLoopRig()
		defer { rig.close() }
		rig.daemon.scripts = [.agent([.start: .drop]), .agent()]
		rig.loop.start()
		#expect(await eventually { rig.recorder.sessions.count == 1 })
		let first = try #require(rig.recorder.sessions.first)
		await #expect(throws: RPCConnection.ConnectionError.self) {
			try await first.start(vm: "Debian", options: StartOptions())
		}
		#expect(await eventually { rig.recorder.sessions.count == 2 })
		#expect(rig.recorder.detaches == 1)
		#expect(rig.recorder.carried == [[], [InterruptedCall(method: .start, vm: "Debian")]])
		#expect(InterruptedActions.message(rig.recorder.carried[1])
			== "Check whether starting Debian finished.")
		#expect(rig.loop.status == .connected(daemonVersion: "1.0.12"))
	}
}

// The loop, the fake agent it connects to, and what the loop told the app.
@MainActor
final class SocketLoopRig {
	let daemon: FakeDaemon
	let recorder = SocketLoopRecorder()
	var helloDeadline: Duration
	private(set) var launches = 0
	private(set) var loop: ConnectionLoop<RemoteMachman>!

	init(
		helloDeadline: Duration = .seconds(10), listening: Bool = true,
		listenOnLaunch: Bool = false
	) throws {
		daemon = try FakeDaemon(listening: listening)
		self.helloDeadline = helloDeadline
		let daemon = self.daemon
		let recorder = self.recorder
		loop = ConnectionLoop(
			policy: .fast(maxAttempts: 5),
			connect: { [unowned self] onDrop in
				try await daemon.remote(helloDeadline: self.helloDeadline, onDrop: onDrop)
			},
			launchDaemon: { [unowned self] in
				launches += 1
				if listenOnLaunch { try? daemon.listen() }
			},
			attach: { session, interrupted in
				recorder.sessions.append(session)
				recorder.carried.append(interrupted)
			},
			detach: { recorder.detaches += 1 },
			onStatus: { recorder.statuses.append($0) })
	}

	// The agent goes, and with it every session the loop attached.
	func close() {
		daemon.close()
		let sessions = recorder.sessions
		Task {
			for session in sessions { await session.disconnect() }
		}
	}
}

@MainActor
final class SocketLoopRecorder {
	var sessions: [RemoteMachman] = []
	var carried: [[InterruptedCall]] = []   // per attach, what it was handed
	var detaches = 0
	var statuses: [ConnectionStatus] = []
}
