//
//  FakeSession.swift
//  MachmanDesktopCoreTests
//
//  The connect loop's world without a socket: FakeSession behaves like an armed RemoteMachman
//  (its disconnect reports the drop once, and so does the agent going away), FakeConnector
//  plays a script of attempt outcomes and counts connects and agent launches, and
//  LoopRecorder keeps what the loop told the app.
//

import Foundation
import MachmanAPI
import MachmanClient
import MachmanFixtures
@testable import MachmanDesktopCore

@MainActor
final class FakeSession: DaemonSession {
	let name: String
	let api: MachmanControlling
	let daemonVersion: String
	var subscribeError: Error?
	// What this session's drop cut off, as RemoteMachman.interruptedCalls() would report it.
	var interrupted: [InterruptedCall] = []
	private(set) var subscribes = 0
	private(set) var disconnects = 0
	fileprivate(set) var onDrop: (@Sendable () -> Void)?
	private var dead = false

	init(_ name: String, daemonVersion: String = "1.0.10") {
		self.name = name
		self.api = StubMachman()
		self.daemonVersion = daemonVersion
	}

	func subscribeEvents() async throws {
		subscribes += 1
		if let subscribeError { throw subscribeError }
	}

	func disconnect() async {
		disconnects += 1
		die()
	}

	func interruptedCalls() async -> [InterruptedCall] {
		interrupted
	}

	// The agent's end went away: the drop is reported once, like RPCConnection's teardown.
	func die() {
		guard !dead else { return }
		dead = true
		onDrop?()
	}
}

@MainActor
final class FakeConnector {
	enum Outcome {
		case session(FakeSession)
		// The session reports its drop before connect returns (it died on the way in).
		case droppedSession(FakeSession)
		// reportsDrop: the failure also fires onDrop, as a failed hello did before P1's fix.
		case failure(Error, reportsDrop: Bool = false)
		// Parks until resumeParked(with:): an attempt still in flight.
		case suspended
	}

	static let refused = RPCConnection.ConnectionError.connectFailed(
		"/var/empty/machman.sock", ECONNREFUSED)
	static let silent = MachmanError(
		code: .timeout,
		message: "no reply to machman.hello after 10s — the serving process may be hung")
	static let mismatch = RemoteMachman.APIVersionMismatch(daemonAPI: 2, clientAPI: 1)

	var script: [Outcome] = []
	var otherwise: Outcome = .failure(FakeConnector.refused)
	private(set) var connects = 0
	private(set) var launches = 0
	private var parked: [(CheckedContinuation<FakeSession, Error>, @Sendable () -> Void)] = []

	var parkedCount: Int { parked.count }

	func connect(_ onDrop: @escaping @Sendable () -> Void) async throws -> FakeSession {
		connects += 1
		let outcome = script.isEmpty ? otherwise : script.removeFirst()
		switch outcome {
		case .session(let session):
			session.onDrop = onDrop
			return session
		case .droppedSession(let session):
			session.onDrop = onDrop
			session.die()
			return session
		case .failure(let error, let reportsDrop):
			if reportsDrop { onDrop() }
			throw error
		case .suspended:
			return try await withCheckedThrowingContinuation { continuation in
				parked.append((continuation, onDrop))
			}
		}
	}

	func resumeParked(with session: FakeSession) {
		let (continuation, onDrop) = parked.removeFirst()
		session.onDrop = onDrop
		continuation.resume(returning: session)
	}

	func launch() {
		launches += 1
	}
}

@MainActor
final class LoopRecorder {
	var attached: [FakeSession] = []
	var carried: [[InterruptedCall]] = []   // per attach, what it was handed
	var detaches = 0
	var statuses: [ConnectionStatus] = []

	var attachedNames: [String] { attached.map(\.name) }
}

extension ConnectionPolicy {
	// The standard bounds with no waiting between attempts.
	static func fast(
		maxAttempts: Int = 20, healthySession: Duration = .seconds(10)
	) -> ConnectionPolicy {
		ConnectionPolicy(
			maxAttempts: maxAttempts, retryDelay: .milliseconds(1),
			healthySession: healthySession)
	}
}

@MainActor
func makeLoop(
	_ connector: FakeConnector, _ recorder: LoopRecorder, policy: ConnectionPolicy = .fast()
) -> ConnectionLoop<FakeSession> {
	ConnectionLoop(
		policy: policy,
		connect: { try await connector.connect($0) },
		launchDaemon: { connector.launch() },
		attach: { session, interrupted in
			recorder.attached.append(session)
			recorder.carried.append(interrupted)
		},
		detach: { recorder.detaches += 1 },
		onStatus: { recorder.statuses.append($0) })
}

extension ConnectionStatus {
	var problemKind: ConnectionProblem.Kind? {
		if case .unavailable(let problem) = self { return problem.kind }
		return nil
	}
}
